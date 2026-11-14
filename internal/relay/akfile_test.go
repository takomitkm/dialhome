package relay

import (
	"sort"
	"strings"
	"testing"

	"github.com/takomitkm/dialhome/internal/crypto"
)

func foreignAK() string {
	return strings.Join([]string{
		"# someone else's key",
		"ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIForeignExampleKeyBody00 foreign@host",
		"",
	}, "\n")
}

func TestParseRecognizesKinds(t *testing.T) {
	helper := "C:/dialhome/dialhome.exe"
	pub, _ := crypto.Generate("whatever")
	nodeLine := NodeLine(helper, Ports{App: 13440, SSH: 13441}, pub.Public, "hp66")
	credKP, _ := crypto.Generate("whatever")
	credLine := CredentialLine(helper, "cred-1", credKP.Public)

	content := foreignAK() + "\n" + nodeLine + "\n" + credLine + "\n"
	entries := Parse(content)

	kinds := map[string]int{}
	var foundNode, foundCred bool
	for _, e := range entries {
		kinds[e.Kind]++
		if e.Kind == "node" && e.Name == "hp66" {
			foundNode = true
			if len(e.Ports) != 2 {
				t.Fatalf("node line must carry two permitlisten ports: %v", e.Ports)
			}
			// order-insensitive: the template emits ssh first, but the contract is a set
			got := append([]int(nil), e.Ports...)
			sort.Ints(got)
			if got[0] != 13440 || got[1] != 13441 {
				t.Fatalf("ports outside expected pair: %v", e.Ports)
			}
		}
		if e.Kind == "credential" && e.Name == "cred-1" {
			foundCred = true
		}
	}
	if kinds["other"] < 2 || !foundNode || !foundCred {
		t.Fatalf("parse kinds wrong: %v", kinds)
	}
}

func TestRenderIsLosslessForForeignLines(t *testing.T) {
	in := foreignAK()
	out := Render(Parse(in))
	if out != in+"\n" {
		t.Fatalf("foreign content must round-trip byte-for-byte:\nIN : %q\nOUT: %q", in, out)
	}
}

func TestUpsertReplacesOnlyTarget(t *testing.T) {
	pub1, _ := crypto.Generate("n1")
	pub2, _ := crypto.Generate("n2")
	line1 := NodeLine("h", Ports{App: 13440, SSH: 13441}, pub1.Public, "alpha")
	line2 := NodeLine("h", Ports{App: 13442, SSH: 13443}, pub2.Public, "beta")
	entries := Parse(foreignAK() + "\n" + line1 + "\n" + line2 + "\n")

	pub1b, _ := crypto.Generate("n1")
	newLine := NodeLine("h", Ports{App: 13440, SSH: 13441}, pub1b.Public, "alpha")
	entries, replaced := UpsertNode(entries, "alpha", newLine)
	if !replaced {
		t.Fatal("alpha line should be replaced, not appended")
	}
	out := Render(entries)
	if strings.Count(out, "dialhome-node-alpha") != 1 {
		t.Fatalf("alpha must appear exactly once:\n%s", out)
	}
	if !strings.Contains(out, "dialhome-node-beta") {
		t.Fatal("beta line must be untouched")
	}
	if !strings.Contains(out, "foreign@host") {
		t.Fatal("foreign line must be untouched")
	}
}

func TestRemoveNodeOnlyTarget(t *testing.T) {
	pub, _ := crypto.Generate("x")
	lineA := NodeLine("h", Ports{App: 13440, SSH: 13441}, pub.Public, "alpha")
	lineB := NodeLine("h", Ports{App: 13442, SSH: 13443}, pub.Public, "beta")
	entries := Parse(lineA + "\n" + lineB + "\n")
	entries, removed := RemoveNode(entries, "alpha")
	if !removed {
		t.Fatal("alpha should be removed")
	}
	out := Render(entries)
	if strings.Contains(out, "dialhome-node-alpha") || strings.Contains(out, "13440") {
		t.Fatalf("alpha ports must disappear:\n%s", out)
	}
	if !strings.Contains(out, "dialhome-node-beta") {
		t.Fatal("beta must survive")
	}
	if _, removed := RemoveNode(entries, "alpha"); removed {
		t.Fatal("second removal must report absent")
	}
}

func TestNodeLineSecurityBoundary(t *testing.T) {
	pub, _ := crypto.Generate("n")
	line := NodeLine("C:/h.exe", Ports{App: 13440, SSH: 13441}, pub.Public, "hp66")
	for _, want := range []string{
		`restrict,`,
		`port-forwarding`,
		`permitlisten="127.0.0.1:13441"`,
		`permitlisten="127.0.0.1:13440"`,
		`permitopen="127.0.0.1:1"`,
		"dialhome-node-hp66",
	} {
		if !strings.Contains(line, want) {
			t.Fatalf("line missing %q: %s", want, line)
		}
	}
	for _, banned := range []string{"localhost:", "0.0.0.0:"} {
		if strings.Contains(line, banned) {
			t.Fatalf("security boundary violated (%q): %s", banned, line)
		}
	}
}
