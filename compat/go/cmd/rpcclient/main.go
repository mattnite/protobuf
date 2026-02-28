package main

import (
	"fmt"
	"io"
	"os"

	"compat/pb"
	"compat/rpcproto"

	"google.golang.org/protobuf/proto"
)

func main() {
	r := os.Stdin
	w := os.Stdout
	failures := 0

	// Test 1: Ping
	failures += testPing(r, w)
	// Test 2: GetItem
	failures += testGetItem(r, w)
	// Test 3: Health
	failures += testHealth(r, w)
	// Test 4: Echo
	failures += testEcho(r, w)
	// Test 5: ServerSide streaming
	failures += testServerSide(r, w)
	// Test 6: ClientSide streaming
	failures += testClientSide(r, w)
	// Test 7: Bidirectional streaming
	failures += testBidirectional(r, w)

	// Send shutdown
	if err := rpcproto.WriteShutdown(w); err != nil {
		fmt.Fprintf(os.Stderr, "rpcclient: write shutdown: %v\n", err)
		os.Exit(1)
	}

	if failures > 0 {
		fmt.Fprintf(os.Stderr, "rpcclient: %d test(s) failed\n", failures)
		os.Exit(1)
	}
}

func callUnary(r io.Reader, w io.Writer, method string, req proto.Message) ([]byte, error) {
	reqBytes, err := proto.Marshal(req)
	if err != nil {
		return nil, fmt.Errorf("marshal request: %w", err)
	}
	if err := rpcproto.WriteCall(w, method, reqBytes); err != nil {
		return nil, fmt.Errorf("write call: %w", err)
	}
	frame, err := rpcproto.ReadFrame(r)
	if err != nil {
		return nil, fmt.Errorf("read response: %w", err)
	}
	if frame.Type == rpcproto.FrameError {
		return nil, fmt.Errorf("server error: %s", string(frame.Payload))
	}
	if frame.Type != rpcproto.FrameResponse {
		return nil, fmt.Errorf("expected RESPONSE, got 0x%02x", frame.Type)
	}
	return frame.Payload, nil
}

func testPing(r io.Reader, w io.Writer) int {
	respBytes, err := callUnary(r, w, "/UnaryService/Ping", &pb.PingRequest{Payload: "hello"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Ping: %v\n", err)
		return 1
	}
	resp := &pb.PingResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Ping unmarshal: %v\n", err)
		return 1
	}
	if resp.Payload != "hello" {
		fmt.Fprintf(os.Stderr, "FAIL Ping: payload=%q want %q\n", resp.Payload, "hello")
		return 1
	}
	return 0
}

func testGetItem(r io.Reader, w io.Writer) int {
	respBytes, err := callUnary(r, w, "/UnaryService/GetItem", &pb.GetItemRequest{Id: 42, Query: "test"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL GetItem: %v\n", err)
		return 1
	}
	resp := &pb.GetItemResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL GetItem unmarshal: %v\n", err)
		return 1
	}
	if resp.Id != 42 {
		fmt.Fprintf(os.Stderr, "FAIL GetItem: id=%d want 42\n", resp.Id)
		return 1
	}
	if resp.Name != "item_42" {
		fmt.Fprintf(os.Stderr, "FAIL GetItem: name=%q want %q\n", resp.Name, "item_42")
		return 1
	}
	return 0
}

func testHealth(r io.Reader, w io.Writer) int {
	respBytes, err := callUnary(r, w, "/UnaryService/Health", &pb.HealthRequest{ServiceName: "svc"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Health: %v\n", err)
		return 1
	}
	resp := &pb.HealthResponse{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Health unmarshal: %v\n", err)
		return 1
	}
	if resp.Status != "serving" {
		fmt.Fprintf(os.Stderr, "FAIL Health: status=%q want %q\n", resp.Status, "serving")
		return 1
	}
	return 0
}

func testEcho(r io.Reader, w io.Writer) int {
	respBytes, err := callUnary(r, w, "/UnaryService/Echo", &pb.EchoMessage{Text: "hi", Code: 10})
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Echo: %v\n", err)
		return 1
	}
	resp := &pb.EchoMessage{}
	if err := proto.Unmarshal(respBytes, resp); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Echo unmarshal: %v\n", err)
		return 1
	}
	if resp.Text != "hi" {
		fmt.Fprintf(os.Stderr, "FAIL Echo: text=%q want %q\n", resp.Text, "hi")
		return 1
	}
	if resp.Code != 11 {
		fmt.Fprintf(os.Stderr, "FAIL Echo: code=%d want 11\n", resp.Code)
		return 1
	}
	return 0
}

func testServerSide(r io.Reader, w io.Writer) int {
	reqBytes, err := proto.Marshal(&pb.StreamRequest{Query: "q"})
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ServerSide marshal: %v\n", err)
		return 1
	}
	if err := rpcproto.WriteCall(w, "/StreamingService/ServerSide", reqBytes); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ServerSide write call: %v\n", err)
		return 1
	}

	// Read 3 STREAM_MSG + STREAM_END
	for i := int32(0); i < 3; i++ {
		frame, err := rpcproto.ReadFrame(r)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL ServerSide read msg %d: %v\n", i, err)
			return 1
		}
		if frame.Type != rpcproto.FrameStreamMsg {
			fmt.Fprintf(os.Stderr, "FAIL ServerSide: expected STREAM_MSG, got 0x%02x\n", frame.Type)
			return 1
		}
		resp := &pb.StreamResponse{}
		if err := proto.Unmarshal(frame.Payload, resp); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL ServerSide unmarshal %d: %v\n", i, err)
			return 1
		}
		expected := fmt.Sprintf("q_%d", i)
		if resp.Result != expected {
			fmt.Fprintf(os.Stderr, "FAIL ServerSide: result=%q want %q\n", resp.Result, expected)
			return 1
		}
		if resp.Index != i {
			fmt.Fprintf(os.Stderr, "FAIL ServerSide: index=%d want %d\n", resp.Index, i)
			return 1
		}
	}

	frame, err := rpcproto.ReadFrame(r)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ServerSide read end: %v\n", err)
		return 1
	}
	if frame.Type != rpcproto.FrameStreamEnd {
		fmt.Fprintf(os.Stderr, "FAIL ServerSide: expected STREAM_END, got 0x%02x\n", frame.Type)
		return 1
	}
	return 0
}

func testClientSide(r io.Reader, w io.Writer) int {
	// Send CALL with empty request (client streaming)
	if err := rpcproto.WriteCall(w, "/StreamingService/ClientSide", nil); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide write call: %v\n", err)
		return 1
	}

	// Send 3 chunks
	chunks := []string{"a", "bb", "ccc"}
	for _, data := range chunks {
		chunk := &pb.UploadChunk{Data: []byte(data)}
		chunkBytes, err := proto.Marshal(chunk)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL ClientSide marshal chunk: %v\n", err)
			return 1
		}
		if err := rpcproto.WriteStreamMsg(w, chunkBytes); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL ClientSide write chunk: %v\n", err)
			return 1
		}
	}

	// Send STREAM_END
	if err := rpcproto.WriteStreamEnd(w); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide write end: %v\n", err)
		return 1
	}

	// Read RESPONSE
	frame, err := rpcproto.ReadFrame(r)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide read response: %v\n", err)
		return 1
	}
	if frame.Type != rpcproto.FrameResponse {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide: expected RESPONSE, got 0x%02x\n", frame.Type)
		return 1
	}
	resp := &pb.UploadResult{}
	if err := proto.Unmarshal(frame.Payload, resp); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide unmarshal: %v\n", err)
		return 1
	}
	if resp.TotalChunks != 3 {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide: total_chunks=%d want 3\n", resp.TotalChunks)
		return 1
	}
	if resp.Summary != "received_3_chunks" {
		fmt.Fprintf(os.Stderr, "FAIL ClientSide: summary=%q want %q\n", resp.Summary, "received_3_chunks")
		return 1
	}
	return 0
}

func testBidirectional(r io.Reader, w io.Writer) int {
	// Send CALL with empty request (bidi streaming)
	if err := rpcproto.WriteCall(w, "/StreamingService/Bidirectional", nil); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Bidirectional write call: %v\n", err)
		return 1
	}

	// Send 2 messages
	msgs := []struct{ sender, text string }{
		{"test", "hi"},
		{"test", "bye"},
	}
	for _, m := range msgs {
		msg := &pb.ChatMessage{Sender: m.sender, Text: m.text}
		msgBytes, err := proto.Marshal(msg)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional marshal: %v\n", err)
			return 1
		}
		if err := rpcproto.WriteStreamMsg(w, msgBytes); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional write msg: %v\n", err)
			return 1
		}
	}

	// Send STREAM_END
	if err := rpcproto.WriteStreamEnd(w); err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Bidirectional write end: %v\n", err)
		return 1
	}

	// Read 2 echoed messages + STREAM_END
	expectedTexts := []string{"hi", "bye"}
	for i, expectedText := range expectedTexts {
		frame, err := rpcproto.ReadFrame(r)
		if err != nil {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional read msg %d: %v\n", i, err)
			return 1
		}
		if frame.Type != rpcproto.FrameStreamMsg {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional: expected STREAM_MSG, got 0x%02x\n", frame.Type)
			return 1
		}
		resp := &pb.ChatMessage{}
		if err := proto.Unmarshal(frame.Payload, resp); err != nil {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional unmarshal %d: %v\n", i, err)
			return 1
		}
		if resp.Sender != "echo" {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional: sender=%q want %q\n", resp.Sender, "echo")
			return 1
		}
		if resp.Text != expectedText {
			fmt.Fprintf(os.Stderr, "FAIL Bidirectional: text=%q want %q\n", resp.Text, expectedText)
			return 1
		}
	}

	frame, err := rpcproto.ReadFrame(r)
	if err != nil {
		fmt.Fprintf(os.Stderr, "FAIL Bidirectional read end: %v\n", err)
		return 1
	}
	if frame.Type != rpcproto.FrameStreamEnd {
		fmt.Fprintf(os.Stderr, "FAIL Bidirectional: expected STREAM_END, got 0x%02x\n", frame.Type)
		return 1
	}
	return 0
}
