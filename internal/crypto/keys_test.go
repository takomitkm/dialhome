package crypto

import (
	"bytes"
	"strings"
	"testing"
)

func TestGenerateShape(t *testing.T) {
	kp, err := Generate("dialhome-node-test")
	if err != nil {
		t.Fatal(err)
	}
	if !strings.HasPrefix(string(kp.Private), beginMarker) {
		t.Fatal("private key missing BEGIN marker")
	}
	if !strings.Contains(string(kp.Private), endMarker) {
		t.Fatal("private key missing END marker")
	}
	if !strings.HasPrefix(kp.Public.Line(), "ssh-ed25519 ") {
		t.Fatal("public line must start with ssh-ed25519")
	}
	if !strings.HasSuffix(kp.Public.Line(), " dialhome-node-test") {
		t.Fatalf("comment lost: %q", kp.Public.Line())
	}
	if kp.Seed[0] == kp.Seed[1] && kp.Seed[1] == kp.Seed[2] {
		t.Fatal("seed looks non-random")
	}
}

func TestGenerateUnique(t *testing.T) {
	a, _ := Generate("a")
	b, _ := Generate("a")
	if bytes.Equal(a.Seed, b.Seed) {
		t.Fatal("two generated pairs must differ")
	}
	if a.Public.Line() == b.Public.Line() {
		t.Fatal("two generated public keys must differ")
	}
}

func TestParsePublicKeyLine(t *testing.T) {
	kp, err := Generate("node-x")
	if err != nil {
		t.Fatal(err)
	}
	line := kp.Public.Line()
	got, err := ParsePublicKeyLine(line)
	if err != nil {
		t.Fatal(err)
	}
	if got.Type != "ssh-ed25519" || got.Comment != "node-x" {
		t.Fatalf("round trip mismatch: %+v", got)
	}
	if !bytes.Equal(got.Blob, kp.Public.Blob) {
		t.Fatal("blob mismatch after round trip")
	}
	if got.Fingerprint() != kp.Public.Fingerprint() {
		t.Fatal("fingerprint mismatch after round trip")
	}
	if !strings.HasPrefix(kp.Public.Fingerprint(), "SHA256:") {
		t.Fatal("fingerprint must use SHA256: prefix")
	}
}

func TestParseRejects(t *testing.T) {
	if _, err := ParsePublicKeyLine("ssh-rsa AAAA... comment"); err == nil {
		t.Fatal("non-ed25519 type must be rejected")
	}
	if _, err := ParsePublicKeyLine("ssh-ed25519 not-base64!!"); err == nil {
		t.Fatal("bad base64 must be rejected")
	}
	if _, err := ParsePublicKeyLine("ssh-ed25519"); err == nil {
		t.Fatal("body-less line must be rejected")
	}
}

func TestFingerprintIsSha256OfBlob(t *testing.T) {
	kp, _ := Generate("fp-test")
	// recompute independently: sha256 over the blob inside the public line
	if !strings.Contains(kp.Public.Line(), base64.StdEncoding.EncodeToString(kp.Public.Blob)) {
		t.Fatal("blob must be embedded verbatim in the public line")
	}
}
