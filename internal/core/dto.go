package core

type AppStat struct {
	App      string `json:"app"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Total    int64  `json:"total"`
}

type DomainStat struct {
	Host     string `json:"host"`
	Upload   int64  `json:"upload"`
	Download int64  `json:"download"`
	Total    int64  `json:"total"`
}

type AppDetail struct {
	App     string       `json:"app"`
	Domains []DomainStat `json:"domains"`
}

type Point struct {
	Bucket   int64 `json:"bucket"`
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
}

type Summary struct {
	Since    int64 `json:"since"`
	Upload   int64 `json:"upload"`
	Download int64 `json:"download"`
	Total    int64 `json:"total"`
	Apps     int   `json:"apps"`
	Hosts    int   `json:"hosts"`
}

type LiveAppGroup struct {
	App      string `json:"app"`
	UpRate   int64  `json:"upRate"`
	DownRate int64  `json:"downRate"`
	Conns    int    `json:"conns"`
	TopHost  string `json:"topHost"`
}
