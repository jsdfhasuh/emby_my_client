package hybridge

import (
	"encoding/json"
	"errors"
	"io"
	"net"
	"strconv"
	"strings"
	"unicode"
)

type config struct {
	Host         string `json:"host"`
	Port         int    `json:"port"`
	Auth         string `json:"auth"`
	SNI          string `json:"sni"`
	ObfsPassword string `json:"obfsPassword,omitempty"`
}

func parseConfig(raw string) (config, error) {
	var cfg config
	bad := errors.New("HYSTERIA_CONFIG")
	if len(raw) > 32768 {
		return cfg, bad
	}
	d := json.NewDecoder(strings.NewReader(raw))
	d.DisallowUnknownFields()
	if d.Decode(&cfg) != nil || d.Decode(new(any)) != io.EOF || !validHost(cfg.Host) ||
		cfg.Port < 1 || cfg.Port > 65535 || cfg.Auth == "" || len(cfg.Auth) > 4096 ||
		(cfg.SNI != "" && !validHost(cfg.SNI)) || len(cfg.ObfsPassword) > 4096 ||
		(cfg.ObfsPassword != "" && len(cfg.ObfsPassword) < 4) {
		return config{}, bad
	}
	if cfg.SNI == "" {
		cfg.SNI = cfg.Host
	}
	return cfg, nil
}

// Hosts are literal IPs or ASCII DNS names. Destinations are never resolved here.
func validHost(host string) bool {
	if host == "" || len(host) > 253 || strings.IndexFunc(host, unicode.IsSpace) >= 0 {
		return false
	}
	if net.ParseIP(host) != nil {
		return true
	}
	for _, label := range strings.Split(strings.TrimSuffix(host, "."), ".") {
		if len(label) == 0 || len(label) > 63 || label[0] == '-' || label[len(label)-1] == '-' {
			return false
		}
		for _, c := range label {
			if !(c >= 'a' && c <= 'z' || c >= 'A' && c <= 'Z' || c >= '0' && c <= '9' || c == '-') {
				return false
			}
		}
	}
	return true
}

func validAuthority(authority string) bool {
	host, port, err := net.SplitHostPort(authority)
	if err != nil || !validHost(host) {
		return false
	}
	value, err := strconv.Atoi(port)
	return err == nil && value >= 1 && value <= 65535 && strconv.Itoa(value) == port
}
