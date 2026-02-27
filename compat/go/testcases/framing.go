package testcases

import (
	"encoding/binary"
	"fmt"
	"io"

	"google.golang.org/protobuf/proto"
)

// TestCase holds a named protobuf test vector.
type TestCase struct {
	Name string
	Msg  proto.Message
}

// RawTestCase holds a named raw byte slice (decoded from framing).
type RawTestCase struct {
	Name string
	Data []byte
}

// WriteTestCase writes a single test case using 4-byte BE length-prefix framing:
// [4-byte BE name_len][name bytes][4-byte BE msg_len][msg bytes]
func WriteTestCase(w io.Writer, name string, msg proto.Message) error {
	data, err := proto.Marshal(msg)
	if err != nil {
		return fmt.Errorf("marshal %s: %w", name, err)
	}
	return WriteTestCaseRaw(w, name, data)
}

// WriteTestCaseRaw writes a single test case from raw bytes.
func WriteTestCaseRaw(w io.Writer, name string, data []byte) error {
	// Write name length
	if err := binary.Write(w, binary.BigEndian, uint32(len(name))); err != nil {
		return err
	}
	// Write name
	if _, err := w.Write([]byte(name)); err != nil {
		return err
	}
	// Write message length
	if err := binary.Write(w, binary.BigEndian, uint32(len(data))); err != nil {
		return err
	}
	// Write message data
	if _, err := w.Write(data); err != nil {
		return err
	}
	return nil
}

// ReadTestCases reads all framed test cases from raw data.
func ReadTestCases(data []byte) ([]RawTestCase, error) {
	var cases []RawTestCase
	pos := 0

	for pos < len(data) {
		if pos+4 > len(data) {
			return nil, fmt.Errorf("truncated name length at offset %d", pos)
		}
		nameLen := int(binary.BigEndian.Uint32(data[pos : pos+4]))
		pos += 4

		if pos+nameLen > len(data) {
			return nil, fmt.Errorf("truncated name at offset %d", pos)
		}
		name := string(data[pos : pos+nameLen])
		pos += nameLen

		if pos+4 > len(data) {
			return nil, fmt.Errorf("truncated message length at offset %d", pos)
		}
		msgLen := int(binary.BigEndian.Uint32(data[pos : pos+4]))
		pos += 4

		if pos+msgLen > len(data) {
			return nil, fmt.Errorf("truncated message data at offset %d", pos)
		}
		msgData := data[pos : pos+msgLen]
		pos += msgLen

		cases = append(cases, RawTestCase{Name: name, Data: msgData})
	}

	return cases, nil
}
