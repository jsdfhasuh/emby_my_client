// Probe reads one Hysteria2 URI from stdin. Never supply it in argv or env.
package main

import (
	"bufio"
	"crypto/tls"
	"encoding/json"
	"flag"
	"io"
	"log"
	"net/http"
	"net/http/httptrace"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	hybridge "dev.emby/hysteria2/mobile"
)

type report struct {
	Handshake    bool    `json:"handshake"`
	HandshakeMS  int64   `json:"handshakeMs"`
	ConnectHTTPS bool    `json:"connectHttps"`
	Status       int     `json:"httpStatus,omitempty"`
	TTFBMS       int64   `json:"ttfbMs,omitempty"`
	Bytes        int64   `json:"bytes,omitempty"`
	Mbps         float64 `json:"sampleMbps,omitempty"`
	Truncated    bool    `json:"truncated,omitempty"`
	Error        string  `json:"error,omitempty"`
}

func uriConfig(raw string) (map[string]any, bool) {
	u, err := url.Parse(strings.TrimSpace(raw))
	if err != nil || (u.Scheme != "hy2" && u.Scheme != "hysteria2") || u.User == nil ||
		u.Hostname() == "" || (u.Path != "" && u.Path != "/") {
		return nil, false
	}
	q, err := url.ParseQuery(u.RawQuery)
	if err != nil {
		return nil, false
	}
	for key, values := range q {
		if len(values) != 1 {
			return nil, false
		}
		switch key {
		case "sni", "obfs", "obfs-password":
		case "insecure":
			if values[0] != "0" && values[0] != "false" {
				return nil, false
			}
		default:
			return nil, false
		}
	}
	auth := u.User.Username() // net/url has already percent-decoded userinfo.
	if password, ok := u.User.Password(); ok {
		auth += ":" + password
	}
	port := 443
	if u.Port() != "" {
		port, err = strconv.Atoi(u.Port())
		if err != nil {
			return nil, false
		}
	}
	if auth == "" || port < 1 || port > 65535 {
		return nil, false
	}
	sni := q.Get("sni")
	if sni == "" {
		sni = u.Hostname()
	}
	cfg := map[string]any{"host": u.Hostname(), "port": port, "auth": auth, "sni": sni}
	if q.Get("obfs") != "" {
		if q.Get("obfs") != "salamander" || q.Get("obfs-password") == "" {
			return nil, false
		}
		cfg["obfsPassword"] = q.Get("obfs-password")
	} else if q.Has("obfs-password") {
		return nil, false
	}
	return cfg, true
}

func safeCode(err error) string {
	if err == nil {
		return ""
	}
	switch err.Error() {
	case "HYSTERIA_CONFIG":
		return "invalid_config"
	case "HYSTERIA_TLS":
		return "tls_failed"
	case "HYSTERIA_AUTH":
		return "auth_failed"
	case "HYSTERIA_TIMEOUT":
		return "handshake_timeout"
	case "HYSTERIA_CANCELLED":
		return "cancelled"
	default:
		return "handshake_failed"
	}
}

func probe() report {
	r := report{}
	flags := flag.NewFlagSet("probe", flag.ContinueOnError)
	flags.SetOutput(io.Discard)
	target := flags.String("url", "https://example.com/", "non-secret HTTPS target")
	limit := flags.Int64("max-bytes", 8<<20, "maximum throughput sample bytes")
	if flags.Parse(os.Args[1:]) != nil || flags.NArg() != 0 || *limit < 1 || *limit > 256<<20 {
		r.Error = "invalid_flags"
		return r
	}
	u, err := url.Parse(*target)
	if err != nil || u.Scheme != "https" || u.Hostname() == "" || u.User != nil {
		r.Error = "invalid_target"
		return r
	}
	scanner := bufio.NewScanner(io.LimitReader(os.Stdin, 32769))
	scanner.Buffer(make([]byte, 1024), 32768)
	if !scanner.Scan() {
		r.Error = "stdin_required"
		return r
	}
	cfg, ok := uriConfig(scanner.Text())
	if !ok {
		r.Error = "invalid_uri"
		return r
	}
	data, _ := json.Marshal(cfg)
	id, err := hybridge.NewSession(string(data))
	if err != nil {
		r.Error = safeCode(err)
		return r
	}
	defer hybridge.Close(id)
	start := time.Now()
	epJSON, err := hybridge.Connect(id, "")
	r.HandshakeMS = time.Since(start).Milliseconds()
	if err != nil {
		r.Error = safeCode(err)
		return r
	}
	r.Handshake = true
	var ep struct {
		Host               string
		Port               int
		Username, Password string
	}
	if json.Unmarshal([]byte(epJSON), &ep) != nil {
		r.Error = "proxy_failed"
		return r
	}
	proxyURL := &url.URL{Scheme: "http", Host: ep.Host + ":" + strconv.Itoa(ep.Port), User: url.UserPassword(ep.Username, ep.Password)}
	transport := &http.Transport{Proxy: http.ProxyURL(proxyURL), TLSClientConfig: &tls.Config{MinVersion: tls.VersionTLS12},
		TLSHandshakeTimeout: 12 * time.Second, ResponseHeaderTimeout: 20 * time.Second}
	defer transport.CloseIdleConnections()
	client := &http.Client{Transport: transport, Timeout: 45 * time.Second,
		CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	request, err := http.NewRequest(http.MethodGet, u.String(), nil)
	if err != nil {
		r.Error = "invalid_target"
		return r
	}
	start = time.Now()
	request = request.WithContext(httptrace.WithClientTrace(request.Context(), &httptrace.ClientTrace{
		GotFirstResponseByte: func() { r.TTFBMS = time.Since(start).Milliseconds() },
	}))
	response, err := client.Do(request)
	if err != nil {
		r.Error = "connect_https_failed"
		return r
	}
	defer response.Body.Close()
	r.ConnectHTTPS, r.Status = true, response.StatusCode
	r.Bytes, err = io.Copy(io.Discard, io.LimitReader(response.Body, *limit))
	seconds := time.Since(start).Seconds()
	if seconds > 0 {
		r.Mbps = float64(r.Bytes) * 8 / seconds / 1e6
	}
	r.Truncated = r.Bytes == *limit
	if err != nil {
		r.Error = "transfer_failed"
	}
	return r
}

func main() {
	// quic-go can emit generic socket warnings; stdout is exactly one safe JSON.
	log.SetOutput(io.Discard)
	defer func() {
		if recover() != nil {
			_ = json.NewEncoder(os.Stdout).Encode(report{Error: "probe_failed"})
		}
	}()
	_ = json.NewEncoder(os.Stdout).Encode(probe())
}
