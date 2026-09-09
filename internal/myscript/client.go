package myscript

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"time"
)

// Env holds credentials and endpoint loaded from hwr.env.
type Env struct {
	AppKey      string
	HMACKey     string
	Lang        string
	ContentType string
	APIURL      string
}

// LoadEnv reads KEY=VALUE lines from path (shell-style, # comments allowed).
func LoadEnv(path string) (*Env, error) {
	raw, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	env := &Env{
		Lang:        "en_US",
		ContentType: "Text",
		APIURL:      "https://cloud.myscript.com/api/v4.0/iink/batch",
	}
	for _, line := range strings.Split(string(raw), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		k, v, ok := strings.Cut(line, "=")
		if !ok {
			continue
		}
		k = strings.TrimSpace(k)
		v = strings.TrimSpace(v)
		v = strings.Trim(v, `"'`)
		switch k {
		case "APP_KEY":
			env.AppKey = v
		case "HMAC_KEY":
			env.HMACKey = v
		case "LANG":
			env.Lang = v
		case "CONTENT_TYPE":
			env.ContentType = v
		case "API_URL":
			env.APIURL = v
		}
	}
	return env, nil
}

// Client talks to the MyScript batch API.
type Client struct {
	Env        *Env
	HTTP       *http.Client
	MaxRetries int
}

func NewClient(env *Env) *Client {
	return &Client{
		Env: env,
		HTTP: &http.Client{
			Timeout: 60 * time.Second,
		},
		MaxRetries: 3,
	}
}

// Recognize posts body and returns plaintext recognition result.
// Accept: text/plain first; on empty body or 406, retry with
// application/vnd.myscript.jiix and extract .label.
func (c *Client) Recognize(body []byte) (string, error) {
	if c.Env.AppKey == "" {
		return "", fmt.Errorf("myscript: APP_KEY is required")
	}
	// HMAC_KEY may be empty (HMAC disabled in MyScript Cloud dashboard).
	// SignBody still uses secret = APP_KEY + HMAC_KEY.
	text, err := c.doWithAccept(body, "text/plain", false)
	if err == nil && strings.TrimSpace(text) != "" {
		return text, nil
	}
	// Retry as JIIX when plain is empty or 406.
	if err != nil && !isAcceptRetry(err) && strings.TrimSpace(text) != "" {
		return "", err
	}
	jiix, err2 := c.doWithAccept(body, "application/vnd.myscript.jiix", true)
	if err2 != nil {
		if err != nil {
			return "", fmt.Errorf("plain: %v; jiix: %w", err, err2)
		}
		return "", err2
	}
	return jiix, nil
}

type acceptRetryError struct{ status int }

func (e acceptRetryError) Error() string {
	return fmt.Sprintf("accept retry status %d", e.status)
}

func isAcceptRetry(err error) bool {
	_, ok := err.(acceptRetryError)
	return ok
}

func (c *Client) doWithAccept(body []byte, accept string, parseJIXX bool) (string, error) {
	var lastErr error
	backoffs := []time.Duration{5 * time.Second, 15 * time.Second, 15 * time.Second}
	attempts := c.MaxRetries
	if attempts < 1 {
		attempts = 3
	}
	for attempt := 0; attempt < attempts; attempt++ {
		sig := SignBody(c.Env.AppKey, c.Env.HMACKey, body)
		req, err := http.NewRequest(http.MethodPost, c.Env.APIURL, bytes.NewReader(body))
		if err != nil {
			return "", err
		}
		req.Header.Set("Content-Type", "application/json")
		req.Header.Set("Accept", accept)
		req.Header.Set("applicationKey", c.Env.AppKey)
		req.Header.Set("hmac", sig)

		resp, err := c.HTTP.Do(req)
		if err != nil {
			lastErr = err
			if attempt+1 < attempts {
				time.Sleep(backoffs[attempt])
				continue
			}
			return "", err
		}
		raw, _ := io.ReadAll(resp.Body)
		resp.Body.Close()

		switch {
		case resp.StatusCode == http.StatusUnauthorized || resp.StatusCode == http.StatusForbidden:
			return "", fmt.Errorf("myscript: aborting on %d: %s", resp.StatusCode, truncate(raw, 200))
		case resp.StatusCode == http.StatusNotAcceptable:
			return "", acceptRetryError{status: resp.StatusCode}
		case resp.StatusCode == http.StatusTooManyRequests || resp.StatusCode >= 500:
			lastErr = fmt.Errorf("myscript: %d: %s", resp.StatusCode, truncate(raw, 200))
			if attempt+1 < attempts {
				time.Sleep(backoffs[attempt])
				continue
			}
			return "", lastErr
		case resp.StatusCode < 200 || resp.StatusCode >= 300:
			return "", fmt.Errorf("myscript: HTTP %d: %s", resp.StatusCode, truncate(raw, 200))
		}

		if parseJIXX {
			label, err := extractJIXXLabel(raw)
			if err != nil {
				return "", err
			}
			return label, nil
		}
		text := string(raw)
		if strings.TrimSpace(text) == "" {
			return "", acceptRetryError{status: resp.StatusCode}
		}
		return text, nil
	}
	if lastErr != nil {
		return "", lastErr
	}
	return "", fmt.Errorf("myscript: exhausted retries")
}

func extractJIXXLabel(raw []byte) (string, error) {
	var doc struct {
		Label string `json:"label"`
		Type  string `json:"type"`
	}
	if err := json.Unmarshal(raw, &doc); err != nil {
		return "", fmt.Errorf("myscript: parse jiix: %w", err)
	}
	return doc.Label, nil
}

func truncate(b []byte, n int) string {
	s := string(b)
	if len(s) > n {
		return s[:n] + "..."
	}
	return s
}
