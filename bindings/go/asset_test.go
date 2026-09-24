//go:build cgo

package tile57

import (
	"encoding/json"
	"testing"
)

// TestBakeAssets exercises the in-memory portrayal-asset bake against the
// library's embedded S-101 catalogue: all six buffers must be non-empty, the JSON
// ones must start with '{', and the atlas PNGs must carry the PNG magic.
func TestBakeAssets(t *testing.T) {
	a, err := BakeAssets("")
	if err != nil {
		t.Fatalf("BakeAssets: %v", err)
	}
	jsons := []struct {
		name string
		b    []byte
	}{
		{"Colortables", a.Colortables},
		{"Linestyles", a.Linestyles},
		{"SpriteJSON", a.SpriteJSON},
		{"PatternJSON", a.PatternJSON},
	}
	for _, j := range jsons {
		if len(j.b) == 0 || j.b[0] != '{' {
			t.Errorf("%s: want non-empty JSON object, got %d bytes", j.name, len(j.b))
		}
	}
	if !isPNG(a.SpritePNG) {
		t.Errorf("SpritePNG: not a PNG (%d bytes)", len(a.SpritePNG))
	}
	if !isPNG(a.PatternPNG) {
		t.Errorf("PatternPNG: not a PNG (%d bytes)", len(a.PatternPNG))
	}
	t.Logf("assets: colortables=%d linestyles=%d sprite json=%d png=%d pattern json=%d png=%d",
		len(a.Colortables), len(a.Linestyles), len(a.SpriteJSON), len(a.SpritePNG), len(a.PatternJSON), len(a.PatternPNG))
}

func isPNG(b []byte) bool {
	return len(b) > 8 && b[0] == 0x89 && b[1] == 'P' && b[2] == 'N' && b[3] == 'G'
}


func TestBakeMapLibreSprite(t *testing.T) {
	js, png, err := BakeMapLibreSprite("", 1, SchemeDay)
	if err != nil {
		t.Fatal(err)
	}
	if len(js) == 0 {
		t.Fatal("empty MapLibre sprite JSON")
	}
	if len(png) < 8 {
		t.Fatalf("MapLibre sprite PNG too short: %d", len(png))
	}
	if string(png[:8]) != "\x89PNG\r\n\x1a\n" {
		t.Fatalf("MapLibre sprite is not PNG: %x", png[:8])
	}

	var atlas map[string]struct {
		Width      float64 `json:"width"`
		Height     float64 `json:"height"`
		PixelRatio float64 `json:"pixelRatio"`
	}
	if err := json.Unmarshal(js, &atlas); err != nil {
		t.Fatalf("decode MapLibre sprite JSON: %v", err)
	}
	if len(atlas) == 0 {
		t.Fatal("MapLibre sprite JSON has no entries")
	}

	found := false
	for _, cell := range atlas {
		if cell.Width <= 0 || cell.Height <= 0 {
			continue
		}
		if cell.PixelRatio <= 0 {
			t.Fatalf("invalid pixelRatio: %v", cell.PixelRatio)
		}
		found = true
		break
	}
	if !found {
		t.Fatal("MapLibre sprite has no drawable cells")
	}
}
