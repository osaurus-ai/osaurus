// JSON-RPC 2.0 server over stdio, newline-framed (one JSON object per line),
// matching the protocol shape of the pinned `imsg rpc` helper: responses
// carry the request `id`; helper-initiated notifications carry a `method`
// and `params` but no `id`.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
)

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      *int            `json:"id"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

// stdioWriter serializes all stdout writes so responses and asynchronous
// notifications never interleave mid-line.
type stdioWriter struct {
	mu  sync.Mutex
	out *bufio.Writer
}

func newStdioWriter() *stdioWriter {
	return &stdioWriter{out: bufio.NewWriter(os.Stdout)}
}

func (w *stdioWriter) writeLine(payload map[string]any) {
	line, err := json.Marshal(payload)
	if err != nil {
		return
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	w.out.Write(line)
	w.out.WriteByte('\n')
	w.out.Flush()
}

func (w *stdioWriter) respond(id int, result map[string]any) {
	if result == nil {
		result = map[string]any{}
	}
	w.writeLine(map[string]any{"jsonrpc": "2.0", "id": id, "result": result})
}

func (w *stdioWriter) respondError(id int, code int, message string) {
	w.writeLine(map[string]any{
		"jsonrpc": "2.0",
		"id":      id,
		"error":   rpcError{Code: code, Message: message},
	})
}

// notify emits a helper-initiated notification (no id).
func (w *stdioWriter) notify(method string, params map[string]any) {
	if params == nil {
		params = map[string]any{}
	}
	w.writeLine(map[string]any{"jsonrpc": "2.0", "method": method, "params": params})
}

func runRPC(storeDir string) {
	writer := newStdioWriter()
	bridge, err := newBridge(storeDir)
	if err != nil {
		fmt.Fprintf(os.Stderr, "osaurus-wa: cannot open session store: %v\n", err)
		os.Exit(1)
	}
	bridge.writer = writer
	defer bridge.close()

	scanner := bufio.NewScanner(os.Stdin)
	// Requests are small, but allow generous frames for forward compatibility.
	scanner.Buffer(make([]byte, 0, 64*1024), 4*1024*1024)
	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}
		var request rpcRequest
		if err := json.Unmarshal(line, &request); err != nil || request.Method == "" {
			continue
		}
		if request.ID == nil {
			continue // the Swift side never sends notifications
		}
		id := *request.ID
		result, rpcErr := bridge.handle(request.Method, request.Params)
		if rpcErr != nil {
			writer.respondError(id, rpcErr.Code, rpcErr.Message)
		} else {
			writer.respond(id, result)
		}
	}
}
