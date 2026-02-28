package rpcproto

import (
	"encoding/binary"
	"fmt"
	"io"
)

// Frame types for the pipe RPC protocol.
const (
	FrameCall      byte = 0x01
	FrameResponse  byte = 0x02
	FrameStreamMsg byte = 0x03
	FrameStreamEnd byte = 0x04
	FrameError     byte = 0x05
	FrameShutdown  byte = 0x06
)

// Frame represents a single protocol frame.
type Frame struct {
	Type    byte
	Payload []byte
}

// ReadFrame reads a single frame from the reader.
// Format: [1B frame_type][4B BE payload_len][payload bytes]
func ReadFrame(r io.Reader) (*Frame, error) {
	var header [5]byte
	if _, err := io.ReadFull(r, header[:]); err != nil {
		return nil, err
	}

	frameType := header[0]
	payloadLen := binary.BigEndian.Uint32(header[1:5])

	payload := make([]byte, payloadLen)
	if payloadLen > 0 {
		if _, err := io.ReadFull(r, payload); err != nil {
			return nil, err
		}
	}

	return &Frame{Type: frameType, Payload: payload}, nil
}

// WriteFrame writes a single frame to the writer.
func WriteFrame(w io.Writer, frameType byte, payload []byte) error {
	var header [5]byte
	header[0] = frameType
	binary.BigEndian.PutUint32(header[1:5], uint32(len(payload)))
	if _, err := w.Write(header[:]); err != nil {
		return err
	}
	if len(payload) > 0 {
		if _, err := w.Write(payload); err != nil {
			return err
		}
	}
	return nil
}

// WriteCall writes a CALL frame with the given method path and request bytes.
func WriteCall(w io.Writer, method string, reqBytes []byte) error {
	payload := make([]byte, 4+len(method)+len(reqBytes))
	binary.BigEndian.PutUint32(payload[0:4], uint32(len(method)))
	copy(payload[4:4+len(method)], method)
	copy(payload[4+len(method):], reqBytes)
	return WriteFrame(w, FrameCall, payload)
}

// WriteResponse writes a RESPONSE frame.
func WriteResponse(w io.Writer, respBytes []byte) error {
	return WriteFrame(w, FrameResponse, respBytes)
}

// WriteStreamMsg writes a STREAM_MSG frame.
func WriteStreamMsg(w io.Writer, msgBytes []byte) error {
	return WriteFrame(w, FrameStreamMsg, msgBytes)
}

// WriteStreamEnd writes a STREAM_END frame.
func WriteStreamEnd(w io.Writer) error {
	return WriteFrame(w, FrameStreamEnd, nil)
}

// WriteError writes an ERROR frame with the given error message.
func WriteError(w io.Writer, errMsg string) error {
	return WriteFrame(w, FrameError, []byte(errMsg))
}

// WriteShutdown writes a SHUTDOWN frame.
func WriteShutdown(w io.Writer) error {
	return WriteFrame(w, FrameShutdown, nil)
}

// ParseCallPayload extracts the method path and request bytes from a CALL frame payload.
func ParseCallPayload(payload []byte) (method string, reqBytes []byte, err error) {
	if len(payload) < 4 {
		return "", nil, fmt.Errorf("CALL payload too short: %d bytes", len(payload))
	}
	methodLen := binary.BigEndian.Uint32(payload[0:4])
	if 4+int(methodLen) > len(payload) {
		return "", nil, fmt.Errorf("CALL method length %d exceeds payload size %d", methodLen, len(payload))
	}
	method = string(payload[4 : 4+methodLen])
	reqBytes = payload[4+methodLen:]
	return method, reqBytes, nil
}
