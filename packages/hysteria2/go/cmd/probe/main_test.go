package main

import "testing"

func TestURIEncodedCredentials(t *testing.T) {
	cfg, ok := uriConfig("hy2://test%3Aonly%40value@127.0.0.1:443/?sni=localhost&obfs=salamander&obfs-password=test%2Bonly%26value#ignored")
	if !ok || cfg["auth"] != "test:only@value" || cfg["obfsPassword"] != "test+only&value" {
		t.Fatal("percent decoding failed")
	}
	for _, uri := range []string{"hy2://test@localhost/?insecure=1", "hy2://test@localhost/?obfs=other",
		"https://test@localhost", "hy2://test@localhost/?sni=a&sni=b", "hy2://%zz@localhost"} {
		if _, ok := uriConfig(uri); ok {
			t.Fatal("unsafe URI accepted")
		}
	}
}
