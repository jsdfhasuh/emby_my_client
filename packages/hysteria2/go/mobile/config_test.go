package hybridge

import "testing"

func TestConfigStrict(t *testing.T) {
	for _, raw := range []string{
		`{"host":"localhost","port":443,"auth":"test","sni":"localhost","insecure":true}`,
		`{"host":"https://localhost","port":443,"auth":"test","sni":"localhost"}`,
		`{"host":"localhost","port":1.5,"auth":"test","sni":"localhost"}`,
		`{"host":"localhost","port":443,"auth":"test","sni":"localhost","obfsPassword":"abc"}`,
		`{"host":"localhost","port":443,"auth":"test","sni":"localhost"} {}`,
	} {
		if _, err := parseConfig(raw); err == nil || err.Error() != "HYSTERIA_CONFIG" {
			t.Fatal("unsafe config accepted")
		}
	}
	if _, err := parseConfig(`{"host":"::1","port":443,"auth":"test","sni":"localhost","obfsPassword":"test-only"}`); err != nil {
		t.Fatal("valid config rejected")
	}
	for _, target := range []string{"localhost:80", "[::1]:443", "server-only.invalid:12345"} {
		if !validAuthority(target) {
			t.Fatal("valid authority rejected")
		}
	}
	for _, target := range []string{"localhost", "user@localhost:443", "localhost:0", "localhost:65536", "localhost:080", "localhost:443/path"} {
		if validAuthority(target) {
			t.Fatal("invalid authority accepted")
		}
	}
}
