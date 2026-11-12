package pnserver

import (
	"errors"
	"testing"
	"time"
)

func TestExplicitLinkOwnerReusesIdentityAndRejectsEscalation(t *testing.T) {
	s, _ := testStore(t)
	u, err := s.CreateUser("家人", "")
	if err != nil {
		t.Fatal(err)
	}
	a, err := s.CreateUser("管理", "admin")
	if err != nil {
		t.Fatal(err)
	}
	for i := 0; i < 2; i++ {
		f, err := s.IssueUserPairing(u.ID, "", time.Hour)
		if err != nil {
			t.Fatal(err)
		}
		owner, err := s.PairingUserID(f.Enrollment.Token)
		if err != nil || owner != u.ID {
			t.Fatal("wrong grant owner")
		}
		if _, err := s.Enroll(f.Enrollment.Token, "设备"); err != nil {
			t.Fatal(err)
		}
	}
	state, _ := s.Load()
	if len(state.Users) != 2 || len(state.Devices) != 2 {
		t.Fatal("reissuing created another user")
	}
	for _, d := range state.Devices {
		if d.UserID != u.ID {
			t.Fatal("device changed owner")
		}
	}
	if _, err := s.IssueUserPairing(u.ID, "admin", time.Hour); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("privilege escalation")
	}
	if _, err := s.IssueUserPairing(a.ID, "", time.Hour); !errors.Is(err, ErrUnauthorized) {
		t.Fatal("role mismatch accepted")
	}
	if _, err := s.IssueUserPairing("", "", time.Hour); err == nil {
		t.Fatal("missing owner accepted")
	}
	if err := s.RevokeUser(u.ID); err != nil {
		t.Fatal(err)
	}
	if _, err := s.IssueUserPairing(u.ID, "", time.Hour); err == nil {
		t.Fatal("revoked user accepted")
	}
	after, _ := s.Load()
	if len(after.Pairings) != len(state.Pairings) {
		t.Fatal("invalid request created a grant")
	}
}
