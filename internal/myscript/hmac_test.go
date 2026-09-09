package myscript

import (
	"strings"
	"testing"
)

func TestSignBodyKnownVector(t *testing.T) {
	// secret = APP_KEY + HMAC_KEY = "apphmac"; message = "hello"
	// Precomputed: HMAC-SHA512 hex lowercase.
	const want = "4a79cde35418506e18608fcb4664c10aaab2de95978d0162ca6dfc7fe38be768eed9ae6c6d15c718661a40b498a74923853f8be11886e924793f9474d2615fbe"
	got := SignBody("app", "hmac", []byte("hello"))
	if got != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
	if got != strings.ToLower(got) {
		t.Fatal("hmac must be lowercase hex")
	}
	if len(got) != 128 {
		t.Fatalf("len=%d want 128", len(got))
	}

	// Critical: must NOT equal signing with HMAC_KEY alone.
	alone := SignBody("", "hmac", []byte("hello"))
	const aloneWant = "8ec27b12f0867f59f8b34595850ab411d560f88fe1598220af5668b6877b70af3a5565570c5c59585abf461840989332ee489f0a42dc17d2a44a9461905a1e48"
	if alone != aloneWant {
		t.Fatalf("alone hmac mismatch: %s", alone)
	}
	if alone == got {
		t.Fatal("APP_KEY+HMAC_KEY must differ from HMAC_KEY alone")
	}
}

func TestSignBodyDemoJSON(t *testing.T) {
	const want = "dd853101509b03d618a47d45f4bb1a7923da01eb16486f03dab30ac4f7f8fb1d5b3a118a1dd0b62f5c08ad2521d8a70ae794e7d509fcc1fc0c6708ce565746a7"
	got := SignBody("demoAppKey", "demoHmacKey", []byte(`{"contentType":"Text"}`))
	if got != want {
		t.Fatalf("got %s\nwant %s", got, want)
	}
}

func TestSignBodyEmptyHMACKey(t *testing.T) {
	got := SignBody("onlyApp", "", []byte("payload"))
	if got == "" || len(got) != 128 {
		t.Fatalf("empty HMAC_KEY should yield 128-hex digest, got %q", got)
	}
	if got == SignBody("onlyApp", "x", []byte("payload")) {
		t.Fatal("empty HMAC_KEY digest must differ from non-empty")
	}
}
