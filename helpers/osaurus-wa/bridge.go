// whatsmeow wrapper: session store, QR pairing, connection lifecycle, and
// the message/watch surface exposed over JSON-RPC.
package main

import (
	"context"
	"encoding/json"
	"fmt"
	"mime"
	"net/http"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync"
	"time"

	_ "github.com/mattn/go-sqlite3"
	"go.mau.fi/whatsmeow"
	waCompanionReg "go.mau.fi/whatsmeow/proto/waCompanionReg"
	waProto "go.mau.fi/whatsmeow/proto/waE2E"
	"go.mau.fi/whatsmeow/store"
	"go.mau.fi/whatsmeow/store/sqlstore"
	"go.mau.fi/whatsmeow/types"
	"go.mau.fi/whatsmeow/types/events"
	waLog "go.mau.fi/whatsmeow/util/log"
	"google.golang.org/protobuf/proto"
)

type bridge struct {
	container *sqlstore.Container
	client    *whatsmeow.Client
	writer    *stdioWriter

	debug bool

	mu            sync.Mutex
	watching      bool
	downloadMedia bool
	maxMediaBytes int64
	mediaDir      string

	// QR-pairing session state (guarded by mu). The bridge owns login event
	// handling instead of whatsmeow's GetQRChannel because the passkey
	// linking flow (WhatsApp's SHORTCAKE gate) emits non-terminal events and
	// can outlive the QR rotation window; GetQRChannel disconnects as soon
	// as the code pool drains, which would kill a passkey dance in flight.
	loginActive  bool
	loginHandler uint32
	loginQRStop  chan struct{}
	loginTimer   *time.Timer
	passkeyDance bool
}

// stderrLogger routes whatsmeow logs to stderr (stdout carries the JSON-RPC
// stream and must stay clean). Enabled via OSAURUS_WA_DEBUG for diagnosing
// live protocol issues; production runs with waLog.Noop.
type stderrLogger struct{ mod string }

func (l *stderrLogger) logf(level, msg string, args ...any) {
	fmt.Fprintf(
		os.Stderr, "%s [%s %s] %s\n",
		time.Now().Format("15:04:05.000"), l.mod, level, fmt.Sprintf(msg, args...),
	)
}

func (l *stderrLogger) Errorf(msg string, args ...any) { l.logf("ERROR", msg, args...) }
func (l *stderrLogger) Warnf(msg string, args ...any)  { l.logf("WARN", msg, args...) }
func (l *stderrLogger) Infof(msg string, args ...any)  { l.logf("INFO", msg, args...) }
func (l *stderrLogger) Debugf(msg string, args ...any) { l.logf("DEBUG", msg, args...) }
func (l *stderrLogger) Sub(module string) waLog.Logger {
	return &stderrLogger{mod: l.mod + "/" + module}
}

func helperLogger(debug bool) waLog.Logger {
	if debug {
		return &stderrLogger{mod: "wa"}
	}
	return waLog.Noop
}

func newBridge(storeDir string) (*bridge, error) {
	if err := os.MkdirAll(storeDir, 0o700); err != nil {
		return nil, fmt.Errorf("create store dir: %w", err)
	}
	// Primary phones validate the pairing QR's client-type field against the
	// values real WA Web emits and reject the scan outright otherwise
	// (whatsmeow's unset default derives "other web client"). Mirror WA
	// Web's platform (Chrome; the value it reports even from Electron) like
	// other bridges do, and keep the product name in Os so the entry in the
	// phone's Linked Devices list stays identifiable.
	store.DeviceProps.Os = proto.String("Osaurus (Mac OS)")
	store.DeviceProps.PlatformType = waCompanionReg.DeviceProps_CHROME.Enum()
	debug := os.Getenv("OSAURUS_WA_DEBUG") != ""
	dbPath := filepath.Join(storeDir, "whatsapp.db")
	container, err := sqlstore.New(
		context.Background(),
		"sqlite3",
		"file:"+dbPath+"?_foreign_keys=on&_busy_timeout=5000",
		helperLogger(debug),
	)
	if err != nil {
		return nil, fmt.Errorf("open session store: %w", err)
	}
	device, err := container.GetFirstDevice(context.Background())
	if err != nil {
		container.Close()
		return nil, fmt.Errorf("load device: %w", err)
	}
	b := &bridge{container: container, debug: debug}
	b.client = whatsmeow.NewClient(device, helperLogger(debug))
	b.client.AddEventHandler(b.handleEvent)
	return b, nil
}

// resetClientForPairing replaces a dead whatsmeow client with a fresh one.
// After a logout or a remote unlink from the phone, whatsmeow marks the
// device Deleted and swaps all of its session stores for no-op stubs that
// fail every operation (and Connect refuses outright with ErrDeviceDeleted),
// so re-pairing in a long-lived helper process needs a new device + client.
func (b *bridge) resetClientForPairing() {
	old := b.client
	device := b.container.NewDevice()
	client := whatsmeow.NewClient(device, helperLogger(b.debug))
	client.AddEventHandler(b.handleEvent)
	b.mu.Lock()
	b.client = client
	b.mu.Unlock()
	old.RemoveEventHandlers()
	old.Disconnect()
}

// debugf traces bridge-level flow to stderr when OSAURUS_WA_DEBUG is set.
func (b *bridge) debugf(msg string, args ...any) {
	if !b.debug {
		return
	}
	fmt.Fprintf(
		os.Stderr, "%s [bridge] %s\n",
		time.Now().Format("15:04:05.000"), fmt.Sprintf(msg, args...),
	)
}

func (b *bridge) close() {
	b.finishLogin(nil)
	if b.client != nil {
		b.client.Disconnect()
	}
	if b.container != nil {
		b.container.Close()
	}
}

func (b *bridge) selfJID() string {
	if b.client == nil || b.client.Store.ID == nil {
		return ""
	}
	return b.client.Store.ID.String()
}

func (b *bridge) selfNumber() string {
	if b.client == nil || b.client.Store.ID == nil {
		return ""
	}
	return "+" + b.client.Store.ID.User
}

func (b *bridge) selfLID() string {
	if b.client == nil || b.client.Store.LID.IsEmpty() {
		return ""
	}
	return b.client.Store.LID.String()
}

// resolveToPN maps a LID (hidden-user) JID to its phone-number JID when the
// mapping is known, preferring the alt address whatsmeow already resolved on
// the event. Phone-based allowlists depend on this: without it, LID senders
// would never match a `+E.164` entry.
func (b *bridge) resolveToPN(jid types.JID, alt types.JID) types.JID {
	if jid.Server != types.HiddenUserServer {
		return jid
	}
	if !alt.IsEmpty() && alt.Server == types.DefaultUserServer {
		return alt
	}
	if pn, err := b.client.Store.LIDs.GetPNForLID(context.Background(), jid); err == nil && !pn.IsEmpty() {
		return pn
	}
	return jid
}

// ensureConnected connects the client when a device is linked. Callers that
// need an active socket (send, watch, chats) go through this; whatsmeow
// handles reconnects internally once connected.
func (b *bridge) ensureConnected() *rpcError {
	if b.client.Store.ID == nil {
		return &rpcError{Code: -32001, Message: "not linked: scan the QR code in WhatsApp settings first"}
	}
	if b.client.IsConnected() {
		return nil
	}
	if err := b.client.Connect(); err != nil {
		return &rpcError{Code: -32002, Message: "connect failed: " + err.Error()}
	}
	// Give the socket a moment to authenticate so the first send after
	// connect does not race the login handshake.
	deadline := time.Now().Add(15 * time.Second)
	for !b.client.IsLoggedIn() && time.Now().Before(deadline) {
		time.Sleep(100 * time.Millisecond)
	}
	if !b.client.IsLoggedIn() {
		return &rpcError{Code: -32002, Message: "connected but not authenticated within 15s"}
	}
	return nil
}

// MARK: - Dispatch

func (b *bridge) handle(method string, params json.RawMessage) (map[string]any, *rpcError) {
	switch method {
	case "status":
		return b.handleStatus()
	case "login.start":
		return b.handleLoginStart()
	case "login.cancel":
		return b.handleLoginCancel()
	case "login.passkey_response":
		return b.handlePasskeyResponse(params)
	case "login.passkey_confirm":
		return b.handlePasskeyConfirm()
	case "logout":
		return b.handleLogout()
	case "chats.list":
		return b.handleChatsList()
	case "send":
		return b.handleSend(params)
	case "send.attachment":
		return b.handleSendAttachment(params)
	case "message.edit":
		return b.handleEdit(params)
	case "message.revoke":
		return b.handleRevoke(params)
	case "react":
		return b.handleReact(params)
	case "typing":
		return b.handleTyping(params)
	case "read":
		return b.handleRead(params)
	case "watch.subscribe":
		return b.handleWatchSubscribe(params)
	default:
		return nil, &rpcError{Code: -32601, Message: "method not found: " + method}
	}
}

func (b *bridge) handleStatus() (map[string]any, *rpcError) {
	return map[string]any{
		"version":     helperVersion,
		"rpc_methods": rpcMethods,
		"linked":      b.client.Store.ID != nil,
		"connected":   b.client.IsConnected(),
		"logged_in":   b.client.IsLoggedIn(),
		"self_jid":    b.selfJID(),
		"self_number": b.selfNumber(),
		"self_lid":    b.selfLID(),
	}, nil
}

// handleLoginStart begins QR pairing. Returns immediately; QR codes stream
// as `qr` notifications (~20s rotation) until a terminal `login`
// notification (success / timeout / error). Accounts behind WhatsApp's
// passkey linking gate additionally stream `passkey` notifications
// (stage: challenge / confirm) that the app answers via
// `login.passkey_response` and `login.passkey_confirm`.
func (b *bridge) handleLoginStart() (map[string]any, *rpcError) {
	if b.client.Store.ID != nil {
		return map[string]any{"already_linked": true, "self_jid": b.selfJID()}, nil
	}
	b.mu.Lock()
	if b.loginActive {
		b.mu.Unlock()
		return map[string]any{"started": true, "already_pairing": true}, nil
	}
	b.loginActive = true
	b.passkeyDance = false
	b.loginQRStop = make(chan struct{})
	b.mu.Unlock()

	if b.client.Store.Deleted {
		b.resetClientForPairing()
	}
	b.loginHandler = b.client.AddEventHandler(b.handleLoginEvent)
	if err := b.client.Connect(); err != nil {
		b.finishLogin(nil)
		b.client.Disconnect()
		return nil, &rpcError{Code: -32002, Message: "connect failed: " + err.Error()}
	}
	// Overall watchdog. Generous because the passkey flow includes a manual
	// browser round-trip; per-code QR rotation is timed separately below.
	b.loginTimer = time.AfterFunc(10*time.Minute, func() {
		b.finishLogin(map[string]any{"status": "timeout"})
	})
	return map[string]any{"started": true}, nil
}

// finishLogin tears down the pairing session exactly once. A non-nil payload
// is emitted as the terminal `login` notification; pass nil for silent
// cleanup (cancel / process shutdown). Non-success terminals disconnect the
// socket so a dead pairing never lingers.
func (b *bridge) finishLogin(payload map[string]any) {
	b.mu.Lock()
	if !b.loginActive {
		b.mu.Unlock()
		return
	}
	b.loginActive = false
	stop := b.loginQRStop
	b.loginQRStop = nil
	timer := b.loginTimer
	b.loginTimer = nil
	handler := b.loginHandler
	b.loginHandler = 0
	b.mu.Unlock()

	if stop != nil {
		close(stop)
	}
	if timer != nil {
		timer.Stop()
	}
	if handler != 0 {
		// Removing from inside an event handler would deadlock the
		// dispatcher, so always detach in the background.
		go b.client.RemoveEventHandler(handler)
	}
	if payload != nil {
		// Notify first: Disconnect can block behind whatsmeow's socket lock
		// (e.g. an auto-reconnect dial in flight), and it must never delay
		// or eat the terminal notification. Backgrounded because this may
		// run inside a whatsmeow event-dispatch goroutine.
		b.writer.notify("login", payload)
		if payload["status"] != "success" {
			go b.client.Disconnect()
		}
	}
}

// handleLoginEvent drives one pairing session from raw whatsmeow events
// (registered only while a login is active).
func (b *bridge) handleLoginEvent(rawEvt any) {
	// whatsmeow's dispatcher recovers handler panics silently (invisible
	// with the no-op logger), which would strand the pairing session with
	// no terminal notification. Report loudly instead.
	defer func() {
		if r := recover(); r != nil {
			b.finishLogin(map[string]any{
				"status": "error",
				"detail": fmt.Sprintf("internal error handling %T: %v", rawEvt, r),
			})
		}
	}()
	b.mu.Lock()
	active := b.loginActive
	b.mu.Unlock()
	if !active {
		return
	}
	b.debugf("login event %T", rawEvt)
	switch evt := rawEvt.(type) {
	case *events.QR:
		// A second QR event mid-session means the server retired the previous
		// registration material (companion_reg_refresh) and whatsmeow rotated
		// the ADV secret: the old codes are dead, so replace the running
		// emitter with one for the re-rendered batch.
		b.mu.Lock()
		if b.passkeyDance {
			// The phone already scanned; a QR re-render is meaningless now.
			b.mu.Unlock()
			return
		}
		if b.loginQRStop != nil {
			close(b.loginQRStop)
		}
		stop := make(chan struct{})
		b.loginQRStop = stop
		b.mu.Unlock()
		go b.emitLoginQRs(slices.Clone(evt.Codes), stop)
	case *events.PairSuccess:
		b.finishLogin(map[string]any{
			"status":      "success",
			"self_jid":    evt.ID.String(),
			"self_number": "+" + evt.ID.User,
		})
	case *events.PairError:
		b.finishLogin(map[string]any{
			"status": "error",
			"detail": "pairing failed: " + evt.Error.Error(),
		})
	case *events.PairPasskeyRequest:
		// WhatsApp's passkey gate: the account requires a WebAuthn assertion
		// before linking completes. QR rotation is over (the phone already
		// scanned); keep the socket alive and hand the challenge to the app.
		b.mu.Lock()
		b.passkeyDance = true
		stop := b.loginQRStop
		b.loginQRStop = nil
		b.mu.Unlock()
		if stop != nil {
			close(stop)
		}
		publicKeyJSON, err := json.Marshal(evt.PublicKey)
		if err != nil {
			b.finishLogin(map[string]any{
				"status": "error",
				"detail": "passkey challenge could not be encoded: " + err.Error(),
			})
			return
		}
		b.writer.notify("passkey", map[string]any{
			"stage":           "challenge",
			"public_key_json": string(publicKeyJSON),
		})
	case *events.PairPasskeyConfirmation:
		if evt.SkipHandoffUX {
			// Relink continuity was proven cryptographically; whatsmeow says
			// the code display can be skipped, so confirm automatically.
			go func() {
				ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
				defer cancel()
				if err := b.client.SendPasskeyConfirmation(ctx); err != nil {
					b.finishLogin(map[string]any{
						"status": "error",
						"detail": "passkey confirmation failed: " + err.Error(),
					})
				}
			}()
			return
		}
		b.writer.notify("passkey", map[string]any{
			"stage": "confirm",
			"code":  evt.Code,
		})
	case *events.PairPasskeyError:
		b.finishLogin(map[string]any{
			"status": "error",
			"detail": "passkey pairing failed: " + evt.Error.Error(),
		})
	case *events.QRScannedWithoutMultidevice:
		b.finishLogin(map[string]any{
			"status": "error",
			"detail": "the QR code was scanned by a phone without multidevice enabled",
		})
	case *events.ClientOutdated:
		b.finishLogin(map[string]any{
			"status": "error",
			"detail": "err-client-outdated: WhatsApp rejected this helper version; update the osaurus-wa helper",
		})
	case *events.Disconnected:
		b.finishLogin(map[string]any{"status": "timeout"})
	case *events.ConnectFailure:
		b.finishLogin(map[string]any{
			"status": "error",
			"detail": fmt.Sprintf("connect failure: %s", evt.Reason),
		})
	case *events.TemporaryBan:
		b.finishLogin(map[string]any{
			"status": "error",
			"detail": "temporarily banned: " + evt.String(),
		})
	case *events.Connected:
		// Only fires as a pairing terminal when the socket authenticates as
		// an already-linked device (fresh links go through PairSuccess).
		if b.client.Store.ID != nil {
			b.finishLogin(map[string]any{
				"status":      "success",
				"self_jid":    b.selfJID(),
				"self_number": b.selfNumber(),
			})
		}
	}
}

// emitLoginQRs streams one code batch as `qr` notifications, first code 60s
// then 20s each, mirroring whatsmeow's own rotation. `stop` belongs to this
// emitter: it closes when a passkey dance takes over, the session finishes,
// or a refreshed batch replaces this one. Draining the pool without a scan
// times the login out — but only if this emitter is still the active one.
func (b *bridge) emitLoginQRs(codes []string, stop chan struct{}) {
	for i, code := range codes {
		timeout := 20 * time.Second
		if i == 0 {
			timeout = 60 * time.Second
		}
		b.writer.notify("qr", map[string]any{
			"code":       code,
			"timeout_ms": timeout.Milliseconds(),
		})
		select {
		case <-time.After(timeout):
		case <-stop:
			return
		}
	}
	b.mu.Lock()
	current := b.loginQRStop == stop
	b.mu.Unlock()
	if current {
		b.finishLogin(map[string]any{"status": "timeout"})
	}
}

func (b *bridge) handleLoginCancel() (map[string]any, *rpcError) {
	b.finishLogin(nil)
	if b.client.Store.ID == nil {
		b.client.Disconnect()
	}
	return map[string]any{"cancelled": true}, nil
}

type passkeyResponseParams struct {
	ResponseJSON string `json:"response_json"`
}

// handlePasskeyResponse forwards the WebAuthn assertion (the JSON produced
// by `navigator.credentials.get(...)` → `cred.toJSON()` in a
// web.whatsapp.com browser tab) to the server.
func (b *bridge) handlePasskeyResponse(params json.RawMessage) (map[string]any, *rpcError) {
	var p passkeyResponseParams
	if err := json.Unmarshal(params, &p); err != nil || strings.TrimSpace(p.ResponseJSON) == "" {
		return nil, &rpcError{Code: -32602, Message: "invalid params: response_json (string) is required"}
	}
	var resp types.WebAuthnResponse
	if err := json.Unmarshal([]byte(p.ResponseJSON), &resp); err != nil {
		return nil, &rpcError{Code: -32602, Message: "invalid passkey response json: " + err.Error()}
	}
	if resp.ID == "" || len(resp.RawID) == 0 || len(resp.Response.Signature) == 0 {
		return nil, &rpcError{
			Code:    -32602,
			Message: "incomplete passkey response json: id, rawId, and response.signature are required",
		}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := b.client.SendPasskeyResponse(ctx, &resp); err != nil {
		return nil, &rpcError{Code: -32004, Message: "send passkey response: " + err.Error()}
	}
	return map[string]any{"submitted": true}, nil
}

// handlePasskeyConfirm reports that the user verified the on-screen code
// matches their phone, finishing the passkey pairing exchange.
func (b *bridge) handlePasskeyConfirm() (map[string]any, *rpcError) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	if err := b.client.SendPasskeyConfirmation(ctx); err != nil {
		return nil, &rpcError{Code: -32004, Message: "send passkey confirmation: " + err.Error()}
	}
	return map[string]any{"confirmed": true}, nil
}

func (b *bridge) handleLogout() (map[string]any, *rpcError) {
	if b.client.Store.ID == nil {
		return map[string]any{"logged_out": true, "was_linked": false}, nil
	}
	if err := b.client.Logout(context.Background()); err != nil {
		// Logout requires a live connection; fall back to wiping the local
		// device so the helper always ends unlinked (the phone keeps the
		// stale device entry until the user removes it there).
		if deleteErr := b.client.Store.Delete(context.Background()); deleteErr != nil {
			return nil, &rpcError{
				Code:    -32004,
				Message: "logout failed: " + err.Error() + "; local wipe failed: " + deleteErr.Error(),
			}
		}
	}
	return map[string]any{"logged_out": true, "was_linked": true}, nil
}

func (b *bridge) handleChatsList() (map[string]any, *rpcError) {
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	chats := make([]map[string]any, 0, 64)
	groups, err := b.client.GetJoinedGroups(context.Background())
	if err == nil {
		for _, group := range groups {
			chats = append(chats, map[string]any{
				"jid":          group.JID.String(),
				"name":         group.Name,
				"kind":         "group",
				"participants": len(group.Participants),
			})
		}
	}
	contacts, err := b.client.Store.Contacts.GetAllContacts(context.Background())
	if err == nil {
		for jid, info := range contacts {
			if jid.Server != types.DefaultUserServer {
				continue
			}
			name := info.FullName
			if name == "" {
				name = info.PushName
			}
			chats = append(chats, map[string]any{
				"jid":    jid.String(),
				"number": "+" + jid.User,
				"name":   name,
				"kind":   "dm",
			})
		}
	}
	return map[string]any{"chats": chats}, nil
}

// resolveChatJID accepts a raw JID ("...@s.whatsapp.net", "...@g.us") or an
// E.164-ish phone number and returns the target JID.
func resolveChatJID(raw string) (types.JID, error) {
	trimmed := strings.TrimSpace(raw)
	if trimmed == "" {
		return types.EmptyJID, fmt.Errorf("empty recipient")
	}
	if strings.ContainsRune(trimmed, '@') {
		jid, err := types.ParseJID(trimmed)
		if err != nil {
			return types.EmptyJID, fmt.Errorf("invalid JID %q: %w", trimmed, err)
		}
		return jid, nil
	}
	digits := strings.Map(func(r rune) rune {
		if r >= '0' && r <= '9' {
			return r
		}
		return -1
	}, trimmed)
	if len(digits) < 5 {
		return types.EmptyJID, fmt.Errorf("invalid phone number %q", raw)
	}
	return types.NewJID(digits, types.DefaultUserServer), nil
}

type sendParams struct {
	To          string `json:"to"`
	Text        string `json:"text"`
	QuoteID     string `json:"quote_id"`
	QuoteSender string `json:"quote_sender"`
	QuoteText   string `json:"quote_text"`
}

func (b *bridge) handleSend(raw json.RawMessage) (map[string]any, *rpcError) {
	var params sendParams
	if err := json.Unmarshal(raw, &params); err != nil || params.To == "" || params.Text == "" {
		return nil, &rpcError{Code: -32602, Message: "send requires `to` and `text`"}
	}
	chat, err := resolveChatJID(params.To)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	var message *waProto.Message
	if params.QuoteID != "" {
		quotedSender := params.QuoteSender
		if quotedSender == "" {
			quotedSender = chat.String()
		}
		message = &waProto.Message{
			ExtendedTextMessage: &waProto.ExtendedTextMessage{
				Text: proto.String(params.Text),
				ContextInfo: &waProto.ContextInfo{
					StanzaID:    proto.String(params.QuoteID),
					Participant: proto.String(quotedSender),
					QuotedMessage: &waProto.Message{
						Conversation: proto.String(params.QuoteText),
					},
				},
			},
		}
	} else {
		message = &waProto.Message{Conversation: proto.String(params.Text)}
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	response, err := b.client.SendMessage(ctx, chat, message)
	if err != nil {
		return nil, &rpcError{Code: -32005, Message: "send failed: " + err.Error()}
	}
	return map[string]any{
		"message_id": string(response.ID),
		"chat":       chat.String(),
		"timestamp":  response.Timestamp.Unix(),
	}, nil
}

type sendAttachmentParams struct {
	To      string `json:"to"`
	Path    string `json:"path"`
	Caption string `json:"caption"`
	Mime    string `json:"mime"`
}

// maxOutboundAttachmentBytes protects helper memory; WhatsApp's own media
// limits are in the same ballpark for non-document media.
const maxOutboundAttachmentBytes = 128 * 1024 * 1024

func (b *bridge) handleSendAttachment(raw json.RawMessage) (map[string]any, *rpcError) {
	var params sendAttachmentParams
	if err := json.Unmarshal(raw, &params); err != nil || params.To == "" || params.Path == "" {
		return nil, &rpcError{Code: -32602, Message: "send.attachment requires `to` and `path`"}
	}
	chat, err := resolveChatJID(params.To)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	fileInfo, err := os.Stat(params.Path)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: "attachment not readable: " + err.Error()}
	}
	if fileInfo.Size() > maxOutboundAttachmentBytes {
		return nil, &rpcError{Code: -32602, Message: fmt.Sprintf(
			"attachment exceeds %d bytes", maxOutboundAttachmentBytes,
		)}
	}
	data, err := os.ReadFile(params.Path)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: "attachment not readable: " + err.Error()}
	}
	mimetype := strings.TrimSpace(params.Mime)
	if mimetype == "" {
		mimetype = mime.TypeByExtension(strings.ToLower(filepath.Ext(params.Path)))
	}
	if mimetype == "" {
		mimetype = http.DetectContentType(data)
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 120*time.Second)
	defer cancel()

	var mediaKind whatsmeow.MediaType
	switch {
	case strings.HasPrefix(mimetype, "image/") && mimetype != "image/gif":
		mediaKind = whatsmeow.MediaImage
	case strings.HasPrefix(mimetype, "video/"):
		mediaKind = whatsmeow.MediaVideo
	case strings.HasPrefix(mimetype, "audio/"):
		mediaKind = whatsmeow.MediaAudio
	default:
		// GIFs go as documents: WhatsApp's inline "gif" is actually an MP4
		// video, so an honest document upload beats a broken conversion.
		mediaKind = whatsmeow.MediaDocument
	}
	uploaded, err := b.client.Upload(ctx, data, mediaKind)
	if err != nil {
		return nil, &rpcError{Code: -32005, Message: "upload failed: " + err.Error()}
	}

	var caption *string
	if params.Caption != "" {
		caption = proto.String(params.Caption)
	}
	message := &waProto.Message{}
	switch mediaKind {
	case whatsmeow.MediaImage:
		message.ImageMessage = &waProto.ImageMessage{
			URL:           proto.String(uploaded.URL),
			DirectPath:    proto.String(uploaded.DirectPath),
			MediaKey:      uploaded.MediaKey,
			FileEncSHA256: uploaded.FileEncSHA256,
			FileSHA256:    uploaded.FileSHA256,
			FileLength:    proto.Uint64(uploaded.FileLength),
			Mimetype:      proto.String(mimetype),
			Caption:       caption,
		}
	case whatsmeow.MediaVideo:
		message.VideoMessage = &waProto.VideoMessage{
			URL:           proto.String(uploaded.URL),
			DirectPath:    proto.String(uploaded.DirectPath),
			MediaKey:      uploaded.MediaKey,
			FileEncSHA256: uploaded.FileEncSHA256,
			FileSHA256:    uploaded.FileSHA256,
			FileLength:    proto.Uint64(uploaded.FileLength),
			Mimetype:      proto.String(mimetype),
			Caption:       caption,
		}
	case whatsmeow.MediaAudio:
		message.AudioMessage = &waProto.AudioMessage{
			URL:           proto.String(uploaded.URL),
			DirectPath:    proto.String(uploaded.DirectPath),
			MediaKey:      uploaded.MediaKey,
			FileEncSHA256: uploaded.FileEncSHA256,
			FileSHA256:    uploaded.FileSHA256,
			FileLength:    proto.Uint64(uploaded.FileLength),
			Mimetype:      proto.String(mimetype),
		}
	default:
		message.DocumentMessage = &waProto.DocumentMessage{
			URL:           proto.String(uploaded.URL),
			DirectPath:    proto.String(uploaded.DirectPath),
			MediaKey:      uploaded.MediaKey,
			FileEncSHA256: uploaded.FileEncSHA256,
			FileSHA256:    uploaded.FileSHA256,
			FileLength:    proto.Uint64(uploaded.FileLength),
			Mimetype:      proto.String(mimetype),
			FileName:      proto.String(filepath.Base(params.Path)),
			Caption:       caption,
		}
	}
	response, err := b.client.SendMessage(ctx, chat, message)
	if err != nil {
		return nil, &rpcError{Code: -32005, Message: "send failed: " + err.Error()}
	}
	return map[string]any{
		"message_id": string(response.ID),
		"chat":       chat.String(),
		"timestamp":  response.Timestamp.Unix(),
		"mime":       mimetype,
		"size":       len(data),
	}, nil
}

type editParams struct {
	Chat      string `json:"chat"`
	MessageID string `json:"message_id"`
	Text      string `json:"text"`
}

func (b *bridge) handleEdit(raw json.RawMessage) (map[string]any, *rpcError) {
	var params editParams
	if err := json.Unmarshal(raw, &params); err != nil || params.Chat == "" || params.MessageID == "" || params.Text == "" {
		return nil, &rpcError{Code: -32602, Message: "message.edit requires `chat`, `message_id`, and `text`"}
	}
	chat, err := resolveChatJID(params.Chat)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	message := b.client.BuildEdit(
		chat,
		types.MessageID(params.MessageID),
		&waProto.Message{Conversation: proto.String(params.Text)},
	)
	if _, err := b.client.SendMessage(ctx, chat, message); err != nil {
		return nil, &rpcError{Code: -32005, Message: "edit failed: " + err.Error()}
	}
	return map[string]any{"edited": true, "message_id": params.MessageID}, nil
}

type revokeParams struct {
	Chat      string `json:"chat"`
	Sender    string `json:"sender"` // only needed when revoking someone else's message (group admin)
	MessageID string `json:"message_id"`
}

func (b *bridge) handleRevoke(raw json.RawMessage) (map[string]any, *rpcError) {
	var params revokeParams
	if err := json.Unmarshal(raw, &params); err != nil || params.Chat == "" || params.MessageID == "" {
		return nil, &rpcError{Code: -32602, Message: "message.revoke requires `chat` and `message_id`"}
	}
	chat, err := resolveChatJID(params.Chat)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	sender := types.EmptyJID
	if params.Sender != "" {
		if sender, err = resolveChatJID(params.Sender); err != nil {
			return nil, &rpcError{Code: -32602, Message: err.Error()}
		}
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	message := b.client.BuildRevoke(chat, sender, types.MessageID(params.MessageID))
	if _, err := b.client.SendMessage(ctx, chat, message); err != nil {
		return nil, &rpcError{Code: -32005, Message: "revoke failed: " + err.Error()}
	}
	return map[string]any{"revoked": true, "message_id": params.MessageID}, nil
}

type reactParams struct {
	Chat      string `json:"chat"`
	Sender    string `json:"sender"`
	MessageID string `json:"message_id"`
	Emoji     string `json:"emoji"`
}

func (b *bridge) handleReact(raw json.RawMessage) (map[string]any, *rpcError) {
	var params reactParams
	if err := json.Unmarshal(raw, &params); err != nil || params.Chat == "" || params.MessageID == "" {
		return nil, &rpcError{Code: -32602, Message: "react requires `chat` and `message_id`"}
	}
	chat, err := resolveChatJID(params.Chat)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	sender := chat
	if params.Sender != "" {
		if sender, err = resolveChatJID(params.Sender); err != nil {
			return nil, &rpcError{Code: -32602, Message: err.Error()}
		}
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	// Empty emoji removes an existing reaction (WhatsApp semantics).
	message := b.client.BuildReaction(chat, sender, types.MessageID(params.MessageID), params.Emoji)
	if _, err := b.client.SendMessage(ctx, chat, message); err != nil {
		return nil, &rpcError{Code: -32005, Message: "react failed: " + err.Error()}
	}
	return map[string]any{"sent": true}, nil
}

type typingParams struct {
	Chat  string `json:"chat"`
	State string `json:"state"` // composing | paused
}

func (b *bridge) handleTyping(raw json.RawMessage) (map[string]any, *rpcError) {
	var params typingParams
	if err := json.Unmarshal(raw, &params); err != nil || params.Chat == "" {
		return nil, &rpcError{Code: -32602, Message: "typing requires `chat`"}
	}
	chat, err := resolveChatJID(params.Chat)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	state := types.ChatPresenceComposing
	if params.State == "paused" {
		state = types.ChatPresencePaused
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := b.client.SendChatPresence(ctx, chat, state, types.ChatPresenceMediaText); err != nil {
		return nil, &rpcError{Code: -32005, Message: "typing failed: " + err.Error()}
	}
	return map[string]any{"sent": true}, nil
}

type readParams struct {
	Chat       string   `json:"chat"`
	Sender     string   `json:"sender"`
	MessageIDs []string `json:"message_ids"`
}

func (b *bridge) handleRead(raw json.RawMessage) (map[string]any, *rpcError) {
	var params readParams
	if err := json.Unmarshal(raw, &params); err != nil || params.Chat == "" || len(params.MessageIDs) == 0 {
		return nil, &rpcError{Code: -32602, Message: "read requires `chat` and `message_ids`"}
	}
	chat, err := resolveChatJID(params.Chat)
	if err != nil {
		return nil, &rpcError{Code: -32602, Message: err.Error()}
	}
	sender := chat
	if params.Sender != "" {
		if sender, err = resolveChatJID(params.Sender); err != nil {
			return nil, &rpcError{Code: -32602, Message: err.Error()}
		}
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	ids := make([]types.MessageID, 0, len(params.MessageIDs))
	for _, id := range params.MessageIDs {
		ids = append(ids, types.MessageID(id))
	}
	ctx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := b.client.MarkRead(ctx, ids, time.Now(), chat, sender); err != nil {
		return nil, &rpcError{Code: -32005, Message: "mark read failed: " + err.Error()}
	}
	return map[string]any{"sent": true}, nil
}

type watchParams struct {
	DownloadMedia bool   `json:"download_media"`
	MaxMediaBytes int64  `json:"max_media_bytes"`
	MediaDir      string `json:"media_dir"`
}

func (b *bridge) handleWatchSubscribe(raw json.RawMessage) (map[string]any, *rpcError) {
	var params watchParams
	if len(raw) > 0 {
		_ = json.Unmarshal(raw, &params) // params are optional; zero values disable media
	}
	if rpcErr := b.ensureConnected(); rpcErr != nil {
		return nil, rpcErr
	}
	b.mu.Lock()
	b.watching = true
	b.downloadMedia = params.DownloadMedia && params.MediaDir != ""
	b.maxMediaBytes = params.MaxMediaBytes
	b.mediaDir = params.MediaDir
	b.mu.Unlock()
	return map[string]any{
		"subscribed": true,
		"self_jid":   b.selfJID(),
		"self_lid":   b.selfLID(),
	}, nil
}

// MARK: - Event stream

func (b *bridge) isWatching() bool {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.watching
}

func (b *bridge) handleEvent(evt any) {
	if b.writer == nil {
		return
	}
	switch v := evt.(type) {
	case *events.Message:
		if !b.isWatching() {
			return
		}
		b.emitMessage(v)
	case *events.Connected:
		if b.isWatching() {
			b.writer.notify("status", map[string]any{"state": "connected"})
		}
	case *events.Disconnected:
		if b.isWatching() {
			b.writer.notify("status", map[string]any{"state": "disconnected"})
		}
	case *events.LoggedOut:
		// Terminal: the phone unlinked this device. The watch consumer must
		// surface "re-scan QR" instead of retrying silently.
		b.writer.notify("error", map[string]any{
			"reason": "logged_out",
			"detail": "This device was unlinked from the WhatsApp account. Re-link with a new QR code.",
		})
	}
}

// messageText extracts visible text or a media placeholder from a message,
// unwrapping ephemeral/view-once containers.
func messageText(message *waProto.Message) (text string, mediaType string) {
	if message == nil {
		return "", ""
	}
	if wrapped := message.GetEphemeralMessage(); wrapped != nil {
		return messageText(wrapped.GetMessage())
	}
	if wrapped := message.GetViewOnceMessage(); wrapped != nil {
		return messageText(wrapped.GetMessage())
	}
	if conversation := message.GetConversation(); conversation != "" {
		return conversation, ""
	}
	if extended := message.GetExtendedTextMessage(); extended != nil {
		return extended.GetText(), ""
	}
	if image := message.GetImageMessage(); image != nil {
		return image.GetCaption(), "image"
	}
	if video := message.GetVideoMessage(); video != nil {
		return video.GetCaption(), "video"
	}
	if message.GetAudioMessage() != nil {
		return "", "audio"
	}
	if document := message.GetDocumentMessage(); document != nil {
		return document.GetCaption(), "document"
	}
	if message.GetStickerMessage() != nil {
		return "", "sticker"
	}
	if message.GetContactMessage() != nil {
		return "", "contact"
	}
	if message.GetLocationMessage() != nil {
		return "", "location"
	}
	return "", ""
}

// messageContextInfo returns the ContextInfo carried by whichever submessage
// is present — plain extended text, media captions, stickers, contacts,
// locations — unwrapping ephemeral/view-once containers. Mentions and quoted
// replies live here regardless of the message type.
func messageContextInfo(message *waProto.Message) *waProto.ContextInfo {
	if message == nil {
		return nil
	}
	if wrapped := message.GetEphemeralMessage(); wrapped != nil {
		return messageContextInfo(wrapped.GetMessage())
	}
	if wrapped := message.GetViewOnceMessage(); wrapped != nil {
		return messageContextInfo(wrapped.GetMessage())
	}
	if extended := message.GetExtendedTextMessage(); extended != nil {
		return extended.GetContextInfo()
	}
	if image := message.GetImageMessage(); image != nil {
		return image.GetContextInfo()
	}
	if video := message.GetVideoMessage(); video != nil {
		return video.GetContextInfo()
	}
	if audio := message.GetAudioMessage(); audio != nil {
		return audio.GetContextInfo()
	}
	if document := message.GetDocumentMessage(); document != nil {
		return document.GetContextInfo()
	}
	if sticker := message.GetStickerMessage(); sticker != nil {
		return sticker.GetContextInfo()
	}
	if contact := message.GetContactMessage(); contact != nil {
		return contact.GetContextInfo()
	}
	if location := message.GetLocationMessage(); location != nil {
		return location.GetContextInfo()
	}
	return nil
}

func (b *bridge) emitMessage(evt *events.Message) {
	info := evt.Info
	// Ignore protocol chatter, status broadcasts, and newsletters; the v1
	// channel handles DMs and groups only.
	if info.Chat.Server == types.BroadcastServer || info.Chat.Server == "newsletter" {
		return
	}
	text, mediaType := messageText(evt.Message)
	if evt.Message.GetReactionMessage() != nil || evt.Message.GetProtocolMessage() != nil {
		return
	}
	if text == "" && mediaType == "" {
		return
	}

	sender := b.resolveToPN(info.Sender, info.SenderAlt)
	chat := info.Chat
	if !info.IsGroup {
		// DM chats addressed by LID collapse to the peer's phone JID so
		// rows match +E.164 chat allowlists. Inbound: the peer is the
		// sender; own echoes: the peer is the recipient.
		if info.IsFromMe {
			chat = b.resolveToPN(info.Chat, info.RecipientAlt)
		} else {
			chat = b.resolveToPN(info.Chat, info.SenderAlt)
		}
	}

	mentions := []string{}
	var quoteID, quoteSender, quoteText string
	if ctxInfo := messageContextInfo(evt.Message); ctxInfo != nil {
		for _, raw := range ctxInfo.GetMentionedJID() {
			if jid, err := types.ParseJID(raw); err == nil {
				mentions = append(mentions, b.resolveToPN(jid, types.EmptyJID).String())
			} else {
				mentions = append(mentions, raw)
			}
		}
		if quoteID = ctxInfo.GetStanzaID(); quoteID != "" {
			if participant := ctxInfo.GetParticipant(); participant != "" {
				if jid, err := types.ParseJID(participant); err == nil {
					quoteSender = b.resolveToPN(jid, types.EmptyJID).String()
				} else {
					quoteSender = participant
				}
			}
			quoteText, _ = messageText(ctxInfo.GetQuotedMessage())
		}
	}

	params := map[string]any{
		"id":         string(info.ID),
		"chat":       chat.String(),
		"sender":     sender.String(),
		"push_name":  info.PushName,
		"text":       text,
		"media_type": mediaType,
		"timestamp":  info.Timestamp.Unix(),
		"is_group":   info.IsGroup,
		"is_from_me": info.IsFromMe,
		"mentions":   mentions,
	}
	if sender.Server == types.DefaultUserServer {
		params["sender_number"] = "+" + sender.User
	}
	if info.Sender.Server == types.HiddenUserServer {
		params["sender_lid"] = info.Sender.String()
	}
	if quoteID != "" {
		params["quote_id"] = quoteID
		params["quote_sender"] = quoteSender
		params["quote_text"] = quoteText
	}
	if info.IsGroup {
		if groupInfo, err := b.client.GetGroupInfo(context.Background(), info.Chat); err == nil {
			params["group_name"] = groupInfo.Name
		}
	}
	for key, value := range b.downloadInboundMedia(evt, mediaType) {
		params[key] = value
	}
	b.writer.notify("message", params)
}

// MARK: - Inbound media download

// mediaPayload returns the downloadable part of a message plus its declared
// mimetype, filename (documents), and size, unwrapping containers.
func mediaPayload(message *waProto.Message) (part whatsmeow.DownloadableMessage, mimetype string, filename string, size uint64) {
	if message == nil {
		return nil, "", "", 0
	}
	if wrapped := message.GetEphemeralMessage(); wrapped != nil {
		return mediaPayload(wrapped.GetMessage())
	}
	if wrapped := message.GetViewOnceMessage(); wrapped != nil {
		return mediaPayload(wrapped.GetMessage())
	}
	if image := message.GetImageMessage(); image != nil {
		return image, image.GetMimetype(), "", image.GetFileLength()
	}
	if video := message.GetVideoMessage(); video != nil {
		return video, video.GetMimetype(), "", video.GetFileLength()
	}
	if audio := message.GetAudioMessage(); audio != nil {
		return audio, audio.GetMimetype(), "", audio.GetFileLength()
	}
	if document := message.GetDocumentMessage(); document != nil {
		return document, document.GetMimetype(), document.GetFileName(), document.GetFileLength()
	}
	if sticker := message.GetStickerMessage(); sticker != nil {
		return sticker, sticker.GetMimetype(), "", sticker.GetFileLength()
	}
	return nil, "", "", 0
}

// sanitizeFileName keeps a conservative character set so helper-written media
// paths cannot traverse or hide (no separators, no leading dots).
func sanitizeFileName(name string) string {
	cleaned := strings.Map(func(r rune) rune {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9':
			return r
		case r == '.', r == '-', r == '_':
			return r
		default:
			return '_'
		}
	}, name)
	cleaned = strings.TrimLeft(cleaned, ".")
	if len(cleaned) > 120 {
		cleaned = cleaned[len(cleaned)-120:]
	}
	return cleaned
}

func extensionForMime(mimetype, mediaType string) string {
	base := mimetype
	if i := strings.Index(base, ";"); i >= 0 {
		base = strings.TrimSpace(base[:i])
	}
	switch base {
	case "image/jpeg":
		return ".jpg"
	case "image/png":
		return ".png"
	case "image/webp":
		return ".webp"
	case "image/gif":
		return ".gif"
	case "video/mp4":
		return ".mp4"
	case "audio/ogg":
		return ".ogg"
	case "audio/mpeg":
		return ".mp3"
	case "audio/mp4":
		return ".m4a"
	case "application/pdf":
		return ".pdf"
	}
	if exts, err := mime.ExtensionsByType(base); err == nil && len(exts) > 0 {
		return exts[0]
	}
	switch mediaType {
	case "image":
		return ".jpg"
	case "video":
		return ".mp4"
	case "audio":
		return ".m4a"
	case "sticker":
		return ".webp"
	}
	return ".bin"
}

// downloadInboundMedia downloads a watched message's media into the
// Swift-provided media directory and returns the extra notification fields.
// Failures degrade to a `media_skipped` reason — the message itself (caption
// or placeholder) still flows.
func (b *bridge) downloadInboundMedia(evt *events.Message, mediaType string) map[string]any {
	b.mu.Lock()
	enabled := b.downloadMedia
	maxBytes := b.maxMediaBytes
	dir := b.mediaDir
	b.mu.Unlock()
	if !enabled || dir == "" || mediaType == "" {
		return nil
	}
	part, mimetype, filename, size := mediaPayload(evt.Message)
	if part == nil {
		return nil
	}
	if maxBytes > 0 && size > uint64(maxBytes) {
		return map[string]any{"media_skipped": "too_large", "media_size": size}
	}
	data, err := b.client.Download(context.Background(), part)
	if err != nil {
		return map[string]any{"media_skipped": "download_failed"}
	}
	name := sanitizeFileName(filename)
	if name == "" {
		name = sanitizeFileName(string(evt.Info.ID)) + extensionForMime(mimetype, mediaType)
	} else {
		name = sanitizeFileName(string(evt.Info.ID)) + "-" + name
	}
	chatDir := filepath.Join(dir, sanitizeFileName(evt.Info.Chat.User))
	if err := os.MkdirAll(chatDir, 0o700); err != nil {
		return map[string]any{"media_skipped": "write_failed"}
	}
	path := filepath.Join(chatDir, name)
	if err := os.WriteFile(path, data, 0o600); err != nil {
		return map[string]any{"media_skipped": "write_failed"}
	}
	return map[string]any{
		"media_path": path,
		"media_mime": mimetype,
		"media_size": len(data),
		"filename":   name,
	}
}
