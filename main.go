package main

import (
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net/http"
	"os"
	"os/exec"
	"sort"
	"strings"
	"time"
)

// AdGuard API structures
type Rewrite struct {
	Domain string `json:"domain"`
	Answer string `json:"answer"`
}

type VMResource struct {
	VMID   int    `json:"vmid"`
	Name   string `json:"name"`
	Type   string `json:"type"`
	Status string `json:"status"`
}

type Config struct {
	AdGuardHost string
	AdGuardPort string
	AdGuardUser string
	AdGuardPass string
	DNSDomain   string
	DryRun      bool
	Verbose     bool
}

type SyncStats struct {
	Added   int
	Updated int
	Deleted int
	Skipped int
}

func log(msg string) {
	fmt.Printf("[%s] [INFO] %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
}

func dbg(verbose bool, msg string) {
	if verbose {
		fmt.Printf("[%s] [DBG ] %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
	}
}

func errLog(msg string) {
	fmt.Fprintf(os.Stderr, "[%s] [ERR ] %s\n", time.Now().Format("2006-01-02 15:04:05"), msg)
}

func usage() {
	fmt.Fprintf(os.Stderr, `Usage: %s [-H host] [-P port] -u user -p 'pass' [-D domain] [-d] [-v]

  -H  AdGuard host (default: adguard)
  -P  AdGuard port (default: 3000)
  -u  AdGuard username
  -p  AdGuard password
  -D  DNS suffix (default: '', to disable)
  -d  Dry-run (show what would change, no writes)
  -v  Verbose

Example:
  %s -H 'Adguard_Host' -P 80 -u 'MyUser' -p 'MyPass!' -d -v
`, os.Args[0], os.Args[0])
	os.Exit(1)
}

func fetchProxmoxVMs(verbose bool) ([]VMResource, error) {
	dbg(verbose, "Fetching running containers/VMs from Proxmox...")

	cmd := exec.Command("pvesh", "get", "/cluster/resources", "--type", "vm", "--output-format", "json")
	output, err := cmd.Output()
	if err != nil {
		return nil, fmt.Errorf("pvesh error: %w", err)
	}

	var allResources []VMResource
	if err := json.Unmarshal(output, &allResources); err != nil {
		return nil, fmt.Errorf("json parse error: %w", err)
	}

	// Filter: running + type lxc or qemu
	var filtered []VMResource
	for _, r := range allResources {
		if r.Status == "running" && (r.Type == "lxc" || r.Type == "qemu") {
			filtered = append(filtered, r)
		}
	}

	return filtered, nil
}

func getVMIP(vmid int, vmType string, verbose bool) (string, error) {
	dbg(verbose, fmt.Sprintf("Getting IP for VM %d (type: %s)", vmid, vmType))

	if vmType == "lxc" {
		// pct exec <vmid> -- hostname -I
		cmd := exec.Command("pct", "exec", fmt.Sprintf("%d", vmid), "--", "hostname", "-I")
		output, err := cmd.Output()
		if err != nil {
			dbg(verbose, fmt.Sprintf("Failed to get IP for lxc %d: %v", vmid, err))
			return "", nil // Don't fail, just skip
		}
		parts := strings.Fields(strings.TrimSpace(string(output)))
		if len(parts) > 0 {
			return parts[0], nil
		}
	} else if vmType == "qemu" {
		// qm guest cmd <vmid> network-get-interfaces
		cmd := exec.Command("qm", "guest", "cmd", fmt.Sprintf("%d", vmid), "network-get-interfaces")
		output, err := cmd.Output()
		if err != nil {
			dbg(verbose, fmt.Sprintf("Failed to get IP for qemu %d: %v", vmid, err))
			return "", nil
		}

		var result map[string]interface{}
		if err := json.Unmarshal(output, &result); err != nil {
			return "", nil
		}

		if resultArr, ok := result["result"].([]interface{}); ok {
			for _, item := range resultArr {
				if itemMap, ok := item.(map[string]interface{}); ok {
					if ips, ok := itemMap["ip-addresses"].([]interface{}); ok {
						for _, ip := range ips {
							if ipMap, ok := ip.(map[string]interface{}); ok {
								if family, ok := ipMap["ip-family"].(string); ok && family == "ipv4" {
									if addr, ok := ipMap["address"].(string); ok && !strings.HasPrefix(addr, "127.") {
										return addr, nil
									}
								}
							}
						}
					}
				}
			}
		}
	}

	return "", nil
}

func fetchAdGuardRewrites(config Config, verbose bool) ([]Rewrite, error) {
	dbg(verbose, "Fetching AdGuard rewrites...")

	baseURL := fmt.Sprintf("http://%s:%s", config.AdGuardHost, config.AdGuardPort)
	url := fmt.Sprintf("%s/control/rewrite/list", baseURL)

	req, _ := http.NewRequest("GET", url, nil)
	req.SetBasicAuth(config.AdGuardUser, config.AdGuardPass)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("http error: %w", err)
	}
	defer resp.Body.Close()

	body, _ := io.ReadAll(resp.Body)

	var rewrites []Rewrite
	if err := json.Unmarshal(body, &rewrites); err != nil {
		// Handle null response
		if string(body) == "null" {
			return []Rewrite{}, nil
		}
		return nil, fmt.Errorf("json parse error: %w", err)
	}

	return rewrites, nil
}

func addRewrite(config Config, domain, answer string, verbose bool) error {
	baseURL := fmt.Sprintf("http://%s:%s", config.AdGuardHost, config.AdGuardPort)
	url := fmt.Sprintf("%s/control/rewrite/add", baseURL)

	payload := Rewrite{Domain: domain, Answer: answer}
	data, _ := json.Marshal(payload)

	req, _ := http.NewRequest("POST", url, bytes.NewBuffer(data))
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(config.AdGuardUser, config.AdGuardPass)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return fmt.Errorf("AdGuard API error: %d", resp.StatusCode)
	}

	return nil
}

func deleteRewrite(config Config, domain, answer string, verbose bool) error {
	baseURL := fmt.Sprintf("http://%s:%s", config.AdGuardHost, config.AdGuardPort)
	url := fmt.Sprintf("%s/control/rewrite/delete", baseURL)

	payload := Rewrite{Domain: domain, Answer: answer}
	data, _ := json.Marshal(payload)

	req, _ := http.NewRequest("POST", url, bytes.NewBuffer(data))
	req.Header.Set("Content-Type", "application/json")
	req.SetBasicAuth(config.AdGuardUser, config.AdGuardPass)

	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode >= 400 {
		return fmt.Errorf("AdGuard API error: %d", resp.StatusCode)
	}

	return nil
}

func main() {
	config := Config{
		AdGuardHost: "adguard",
		AdGuardPort: "3000",
	}

	flag.StringVar(&config.AdGuardHost, "H", config.AdGuardHost, "AdGuard host")
	flag.StringVar(&config.AdGuardPort, "P", config.AdGuardPort, "AdGuard port")
	flag.StringVar(&config.AdGuardUser, "u", "", "AdGuard username")
	flag.StringVar(&config.AdGuardPass, "p", "", "AdGuard password")
	flag.StringVar(&config.DNSDomain, "D", "", "DNS suffix")
	flag.BoolVar(&config.DryRun, "d", false, "Dry-run mode")
	flag.BoolVar(&config.Verbose, "v", false, "Verbose output")

	flag.Parse()

	if config.AdGuardUser == "" || config.AdGuardPass == "" {
		errLog("Missing -u user or -p 'pass'")
		usage()
	}

	// Check connectivity
	baseURL := fmt.Sprintf("http://%s:%s", config.AdGuardHost, config.AdGuardPort)
	req, _ := http.NewRequest("GET", fmt.Sprintf("%s/control/status", baseURL), nil)
	req.SetBasicAuth(config.AdGuardUser, config.AdGuardPass)
	client := &http.Client{}
	resp, err := client.Do(req)
	if err != nil {
		errLog(fmt.Sprintf("Cannot reach AdGuard at %s/control/status", baseURL))
		os.Exit(1)
	}
	resp.Body.Close()

	dbg(config.Verbose, fmt.Sprintf("AdGuard OK at %s", baseURL))
	dryRunStr := "no"
	if config.DryRun {
		dryRunStr = "yes"
	}
	log(fmt.Sprintf("Dry-run: %s", dryRunStr))

	// Fetch Proxmox VMs
	vms, err := fetchProxmoxVMs(config.Verbose)
	if err != nil {
		errLog(fmt.Sprintf("Failed to fetch VMs: %v", err))
		os.Exit(1)
	}

	log(fmt.Sprintf("Found %d running containers/VMs", len(vms)))

	if len(vms) == 0 {
		log("Nothing to do.")
		os.Exit(0)
	}

	// Build desired DNS map
	desired := make(map[string]string)
	for _, vm := range vms {
		ip, _ := getVMIP(vm.VMID, vm.Type, config.Verbose)
		if ip == "" {
			dbg(config.Verbose, fmt.Sprintf("Skipping %s (vmid %d, type %s) - no IP", vm.Name, vm.VMID, vm.Type))
			continue
		}

		fqdn := vm.Name
		if config.DNSDomain != "" {
			fqdn = fmt.Sprintf("%s.%s", vm.Name, config.DNSDomain)
		}

		desired[fqdn] = ip
		log(fmt.Sprintf("want: %s -> %s", fqdn, ip))
	}

	if len(desired) == 0 {
		log("No containers/VMs with IPs found; nothing to sync.")
		os.Exit(0)
	}

	// Fetch current AdGuard rewrites
	rewrites, err := fetchAdGuardRewrites(config, config.Verbose)
	if err != nil {
		errLog(fmt.Sprintf("Failed to fetch rewrites: %v", err))
		os.Exit(1)
	}

	current := make(map[string]string)
	for _, r := range rewrites {
		current[r.Domain] = r.Answer
	}

	// --- PHASE 1: SYNC (ADD and UPDATE) ---
	stats := SyncStats{}
	for domain, newIP := range desired {
		oldIP, exists := current[domain]

		if !exists {
			// add new entry
			if config.DryRun {
				log(fmt.Sprintf("[DRY] add %s -> %s", domain, newIP))
				stats.Added++
			} else {
				dbg(config.Verbose, fmt.Sprintf("Adding %s -> %s", domain, newIP))
				if err := addRewrite(config, domain, newIP, config.Verbose); err != nil {
					errLog(fmt.Sprintf("Failed to add %s: %v", domain, err))
				} else {
					log(fmt.Sprintf("added %s -> %s", domain, newIP))
					stats.Added++
				}
			}
		} else if oldIP != newIP {
			// update existing entry
			if config.DryRun {
				log(fmt.Sprintf("[DRY] update %s: %s -> %s", domain, oldIP, newIP))
				stats.Updated++
			} else {
				dbg(config.Verbose, fmt.Sprintf("Updating %s: %s -> %s", domain, oldIP, newIP))
				if err := deleteRewrite(config, domain, oldIP, config.Verbose); err != nil {
					errLog(fmt.Sprintf("Failed to delete old %s: %v", domain, err))
					continue
				}
				if err := addRewrite(config, domain, newIP, config.Verbose); err != nil {
					errLog(fmt.Sprintf("Failed to add new %s: %v", domain, err))
				} else {
					log(fmt.Sprintf("updated %s: %s -> %s", domain, oldIP, newIP))
					stats.Updated++
				}
			}
		} else {
			dbg(config.Verbose, fmt.Sprintf("unchanged %s -> %s", domain, oldIP))
		}
	}

	// --- PHASE 2: DELETE entries in AdGuard that are NOT in DESIRED ---
	var toDelete []string
	for d := range current {
		if _, exists := desired[d]; !exists {
			toDelete = append(toDelete, d)
		}
	}

	if len(toDelete) > 0 {
		sort.Strings(toDelete)

		fmt.Println()
		log(fmt.Sprintf("Found %d AdGuard rewrite(s) not present in Proxmox list", len(toDelete)))

		for _, d := range toDelete {
			ip := current[d]
			fmt.Printf("Delete %s -> %s? [y/N] ", d, ip)
			var resp string
			fmt.Scanln(&resp)

			if strings.ToLower(resp) == "y" || strings.ToLower(resp) == "yes" {
				if config.DryRun {
					log(fmt.Sprintf("[DRY] delete %s -> %s", d, ip))
					stats.Deleted++
				} else {
					dbg(config.Verbose, fmt.Sprintf("Deleting %s -> %s", d, ip))
					if err := deleteRewrite(config, d, ip, config.Verbose); err != nil {
						errLog(fmt.Sprintf("Failed to delete %s: %v", d, err))
					} else {
						log(fmt.Sprintf("deleted %s -> %s", d, ip))
						stats.Deleted++
					}
				}
			} else {
				log(fmt.Sprintf("skipped %s -> %s", d, ip))
				stats.Skipped++
			}
		}
	} else {
		dbg(config.Verbose, "No AdGuard rewrites to delete.")
	}

	// --- COMPLETE ---
	fmt.Println()
	log(fmt.Sprintf("Sync complete. Added: %d, Updated: %d, Deleted: %d, Skipped: %d. Manual DNS entries left untouched.", stats.Added, stats.Updated, stats.Deleted, stats.Skipped))
}
