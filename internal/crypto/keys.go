// Package crypto generates and formats the ed25519 keys dialhome uses, in the
// OpenSSH on-disk format ("openssh-key-v1" container), using only the standard library.
//
// Security contract (docs/SECURITY_MODEL.md):
//   - private keys are generated IN PROCESS on the machine that will use them and are
//     written 0600 by the caller; they never travel over the wire
//   - the container is unencrypted (no passphrase) because the node runs headless;
//     the 0600/0700 permission model is the control, and tests pin it
package crypto

import (
	"bytes"
	"crypto/ed25519"
	"crypto/rand"
	"crypto/sha256"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"strings"
)

const (
	magic       = "openssh-key-v1\x00"
	keyTypeName = "ssh-ed25519"
)

// KeyPair is a generated ed25519 pair in OpenSSH wire forms.
type KeyPair struct {
	Private PEMBlock      // "-----BEGIN OPENSSH PRIVATE KEY-----" armoured
	Public  AuthorizedKey // "ssh-ed25519 AAAA... comment" line
	Seed    ed25519.PrivateKey
}

// AuthorizedKey is a parsed public key line.
type AuthorizedKey struct {
	Type    string
	Blob    []byte // the wire blob (string ssh-ed25519 || string pub)
	Comment string
}

// Line renders the authorized_keys line (without leading/trailing whitespace).
func (a AuthorizedKey) Line() string {
	return a.Type + " " + base64.StdEncoding.EncodeToString(a.Blob) + " " + a.Comment
}

// Fingerprint returns the SHA256 fingerprint in OpenSSH display form.
func (a AuthorizedKey) Fingerprint() string {
	sum := sha256.Sum256(a.Blob)
	return "SHA256:" + base64.RawStdEncoding.EncodeToString(sum[:])
}

// Generate creates a fresh key pair with the given comment.
func Generate(comment string) (KeyPair, error) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		return KeyPair{}, fmt.Errorf("keygen: %w", err)
	}
	return fromSeed(priv, pub, comment)
}

func fromSeed(priv ed25519.PrivateKey, pub ed25519.PublicKey, comment string) (KeyPair, error) {
	if len(priv) != ed25519.PrivateKeySize {
		return KeyPair{}, errors.New("crypto: bad seed size")
	}
	pubBlob := pubBlob(pub)
	var check [4]byte
	if _, err := rand.Read(check[:]); err != nil {
		return KeyPair{}, fmt.Errorf("keygen rand: %w", err)
	}

	var sec bytes.Buffer
	writeUint32(&sec, binary.LittleEndian.Uint32(check[:]))
	writeUint32(&sec, binary.LittleEndian.Uint32(check[:]))
	writeString(&sec, []byte(keyTypeName))
	writeString(&sec, pub)
	writeString(&sec, priv) // 64 bytes: seed || pub
	writeString(&sec, []byte(comment))
	// pad to 8-byte multiple with 1,2,3...
	for pad := byte(1); sec.Len()%8 != 0; pad++ {
		sec.WriteByte(pad)
	}

	var w bytes.Buffer
	w.WriteString(magic)
	writeString(&w, []byte("none")) // ciphername
	writeString(&w, []byte("none")) // kdfname
	writeString(&w, nil)            // kdfoptions
	writeUint32(&w, 1)              // number of keys
	writeString(&w, pubBlob)        // public key
	writeString(&w, sec.Bytes())    // private section

	armoured := armour(w.Bytes())
	return KeyPair{
		Private: PEMBlock(armoured),
		Public: AuthorizedKey{
			Type:    keyTypeName,
			Blob:    pubBlob,
			Comment: comment,
		},
		Seed: priv,
	}, nil
}

// PEMBlock is the armoured OpenSSH private key file body.
type PEMBlock string

const (
	beginMarker = "-----BEGIN OPENSSH PRIVATE KEY-----"
	endMarker   = "-----END OPENSSH PRIVATE KEY-----"
)

func armour(raw []byte) string {
	b64 := base64.StdEncoding.EncodeToString(raw)
	var out bytes.Buffer
	out.WriteString(beginMarker + "\n")
	for len(b64) > 70 {
		out.WriteString(b64[:70] + "\n")
		b64 = b64[70:]
	}
	if b64 != "" {
		out.WriteString(b64 + "\n")
	}
	out.WriteString(endMarker + "\n")
	return out.String()
}

func pubBlob(pub ed25519.PublicKey) []byte {
	var b bytes.Buffer
	writeString(&b, []byte(keyTypeName))
	writeString(&b, pub)
	return b.Bytes()
}

func writeString(w *bytes.Buffer, s []byte) {
	var l [4]byte
	binary.BigEndian.PutUint32(l[:], uint32(len(s)))
	w.Write(l[:])
	w.Write(s)
}

func writeUint32(w *bytes.Buffer, v uint32) {
	var b [4]byte
	binary.BigEndian.PutUint32(b[:], v)
	w.Write(b[:])
}

// ParsePublicKeyLine parses an authorized_keys line ("ssh-ed25519 AAAA... comment...").
// Only ssh-ed25519 is accepted: dialhome mints ed25519 keys exclusively.
func ParsePublicKeyLine(line string) (AuthorizedKey, error) {
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return AuthorizedKey{}, errors.New("crypto: public key line needs at least type and body")
	}
	if fields[0] != keyTypeName {
		return AuthorizedKey{}, fmt.Errorf("crypto: unsupported key type %q (only ssh-ed25519)", fields[0])
	}
	blob, err := base64.StdEncoding.DecodeString(fields[1])
	if err != nil {
		return AuthorizedKey{}, fmt.Errorf("crypto: bad base64 body: %w", err)
	}
	comment := strings.Join(fields[2:], " ")
	return AuthorizedKey{Type: fields[0], Blob: blob, Comment: comment}, nil
}
