package myscript

import (
	"crypto/hmac"
	"crypto/sha512"
	"encoding/hex"
)

// SignBody computes the MyScript batch HMAC:
//
//	secret  = APP_KEY + HMAC_KEY   (concatenation; HMAC_KEY may be empty)
//	digest  = HMAC-SHA512(secret, rawBodyBytes)
//	header  = hex-lowercase encoding of digest
func SignBody(appKey, hmacKey string, body []byte) string {
	secret := []byte(appKey + hmacKey)
	mac := hmac.New(sha512.New, secret)
	_, _ = mac.Write(body)
	return hex.EncodeToString(mac.Sum(nil))
}
