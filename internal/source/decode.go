package source

import "encoding/json"

type wsMetadata struct {
	Network         string `json:"network"`
	DestinationIP   string `json:"destinationIP"`
	DestinationPort string `json:"destinationPort"`
	Host            string `json:"host"`
	Process         string `json:"process"`
	ProcessPath     string `json:"processPath"`
}

type wsConn struct {
	ID       string     `json:"id"`
	Metadata wsMetadata `json:"metadata"`
	Upload   int64      `json:"upload"`
	Download int64      `json:"download"`
	Chains   []string   `json:"chains"`
	Rule     string     `json:"rule"`
}

type wsSnapshot struct {
	Connections []wsConn `json:"connections"`
}

func decodeSnapshot(data []byte, at int64) (Snapshot, error) {
	var w wsSnapshot
	if err := json.Unmarshal(data, &w); err != nil {
		return Snapshot{}, err
	}
	s := Snapshot{At: at, Connections: make([]Connection, 0, len(w.Connections))}
	for _, c := range w.Connections {
		s.Connections = append(s.Connections, Connection{
			ID: c.ID, Process: c.Metadata.Process, ProcessPath: c.Metadata.ProcessPath,
			Host: c.Metadata.Host, DestIP: c.Metadata.DestinationIP, DestPort: c.Metadata.DestinationPort,
			Network: c.Metadata.Network, Chains: c.Chains, Rule: c.Rule,
			Upload: c.Upload, Download: c.Download,
		})
	}
	return s, nil
}
