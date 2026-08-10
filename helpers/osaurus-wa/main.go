// osaurus-wa: WhatsApp Web bridge helper for Osaurus.
//
// Wraps whatsmeow (the Go WhatsApp Web multi-device library) behind the same
// newline-framed JSON-RPC 2.0 stdio protocol the pinned `imsg rpc` helper
// uses, so the Swift side can reuse its process-RPC client shape.
//
// Subcommands:
//
//	osaurus-wa rpc [--store-dir DIR]           long-lived JSON-RPC server on stdio
//	osaurus-wa status --json [--store-dir DIR] one-shot link/status probe
//	osaurus-wa version                         print the helper version
package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
)

const helperVersion = "0.2.3"

var rpcMethods = []string{
	"status",
	"login.start",
	"login.cancel",
	"login.passkey_response",
	"login.passkey_confirm",
	"logout",
	"chats.list",
	"send",
	"send.attachment",
	"message.edit",
	"message.revoke",
	"react",
	"typing",
	"read",
	"watch.subscribe",
}

func defaultStoreDir() string {
	if env := os.Getenv("OSAURUS_WA_STORE_DIR"); env != "" {
		return env
	}
	home, err := os.UserHomeDir()
	if err != nil {
		return filepath.Join(".", "osaurus-wa-session")
	}
	return filepath.Join(home, ".osaurus", "whatsapp", "session")
}

func parseStoreDir(args []string) string {
	dir := defaultStoreDir()
	for i := 0; i < len(args); i++ {
		if args[i] == "--store-dir" && i+1 < len(args) {
			dir = args[i+1]
			i++
		}
	}
	return dir
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: osaurus-wa <rpc|status|version> [--store-dir DIR]")
		os.Exit(2)
	}
	switch os.Args[1] {
	case "version":
		fmt.Println(helperVersion)
	case "status":
		runStatus(parseStoreDir(os.Args[2:]))
	case "rpc":
		runRPC(parseStoreDir(os.Args[2:]))
	default:
		fmt.Fprintf(os.Stderr, "unknown subcommand %q\n", os.Args[1])
		os.Exit(2)
	}
}

// runStatus probes the session store without connecting to WhatsApp and
// prints one JSON line, mirroring `imsg status --json`.
func runStatus(storeDir string) {
	payload := map[string]any{
		"version":     helperVersion,
		"rpc_methods": rpcMethods,
		"store_dir":   storeDir,
		"linked":      false,
	}
	if bridge, err := newBridge(storeDir); err == nil {
		if jid := bridge.selfJID(); jid != "" {
			payload["linked"] = true
			payload["self_jid"] = jid
			payload["self_number"] = bridge.selfNumber()
			payload["self_lid"] = bridge.selfLID()
		}
		bridge.close()
	} else {
		payload["error"] = err.Error()
	}
	line, err := json.Marshal(payload)
	if err != nil {
		os.Exit(1)
	}
	fmt.Println(string(line))
}
