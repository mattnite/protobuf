package main

import (
	"bytes"
	"fmt"
	"os"
	"path/filepath"

	"compat/testcases"
)

type generator struct {
	name  string
	cases []testcases.TestCase
}

func main() {
	generators := []generator{
		{"scalar3", testcases.GenerateScalar3()},
		{"nested3", testcases.GenerateNested3()},
		{"enum3", testcases.GenerateEnum3()},
		{"oneof3", testcases.GenerateOneof3()},
		{"repeated3", testcases.GenerateRepeated3()},
		{"map3", testcases.GenerateMap3()},
		{"optional3", testcases.GenerateOptional3()},
		{"edge3", testcases.GenerateEdge3()},
		{"scalar2", testcases.GenerateScalar2()},
		{"required2", testcases.GenerateRequired2()},
	}

	outDir := filepath.Join("..", "testdata", "go")
	if err := os.MkdirAll(outDir, 0o755); err != nil {
		fmt.Fprintf(os.Stderr, "mkdir %s: %v\n", outDir, err)
		os.Exit(1)
	}

	for _, g := range generators {
		var buf bytes.Buffer
		for _, tc := range g.cases {
			if err := testcases.WriteTestCase(&buf, tc.Name, tc.Msg); err != nil {
				fmt.Fprintf(os.Stderr, "write %s/%s: %v\n", g.name, tc.Name, err)
				os.Exit(1)
			}
		}

		path := filepath.Join(outDir, g.name+".bin")
		if err := os.WriteFile(path, buf.Bytes(), 0o644); err != nil {
			fmt.Fprintf(os.Stderr, "write file %s: %v\n", path, err)
			os.Exit(1)
		}
		fmt.Printf("wrote %s (%d bytes, %d cases)\n", path, buf.Len(), len(g.cases))
	}

	fmt.Println("All Go test vectors generated.")
}
