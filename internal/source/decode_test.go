package source

import "testing"

func TestDecodeSnapshot(t *testing.T) {
	raw := []byte(`{
	  "downloadTotal": 999, "uploadTotal": 888,
	  "connections": [
	    {"id":"c1","metadata":{"network":"tcp","destinationIP":"1.2.3.4","destinationPort":"443",
	      "host":"example.com","process":"Safari","processPath":"/x/Safari"},
	     "upload":100,"download":200,"chains":["proxy","auto"],"rule":"RuleSet"}
	  ]}`)
	s, err := decodeSnapshot(raw, 1234)
	if err != nil {
		t.Fatal(err)
	}
	if s.At != 1234 || len(s.Connections) != 1 {
		t.Fatalf("got At=%d conns=%d", s.At, len(s.Connections))
	}
	c := s.Connections[0]
	if c.ID != "c1" || c.Process != "Safari" || c.Host != "example.com" ||
		c.DestIP != "1.2.3.4" || c.Upload != 100 || c.Download != 200 ||
		len(c.Chains) != 2 || c.Rule != "RuleSet" {
		t.Fatalf("bad decode: %+v", c)
	}
}

func TestDecodeSnapshotNullConnections(t *testing.T) {
	s, err := decodeSnapshot([]byte(`{"connections":null}`), 1)
	if err != nil {
		t.Fatal(err)
	}
	if len(s.Connections) != 0 {
		t.Fatalf("want 0 connections")
	}
}
