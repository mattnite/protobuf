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

	for {
		frame, err := rpcproto.ReadFrame(r)
		if err != nil {
			if err == io.EOF {
				return
			}
			fmt.Fprintf(os.Stderr, "rpcserver: read frame: %v\n", err)
			os.Exit(1)
		}

		switch frame.Type {
		case rpcproto.FrameShutdown:
			return

		case rpcproto.FrameCall:
			method, reqBytes, err := rpcproto.ParseCallPayload(frame.Payload)
			if err != nil {
				rpcproto.WriteError(w, err.Error())
				continue
			}
			if err := handleCall(r, w, method, reqBytes); err != nil {
				fmt.Fprintf(os.Stderr, "rpcserver: %s: %v\n", method, err)
				rpcproto.WriteError(w, err.Error())
			}

		default:
			rpcproto.WriteError(w, fmt.Sprintf("unexpected frame type: 0x%02x", frame.Type))
		}
	}
}

func handleCall(r io.Reader, w io.Writer, method string, reqBytes []byte) error {
	switch method {
	// UnaryService methods
	case "/UnaryService/Ping":
		return handlePing(w, reqBytes)
	case "/UnaryService/GetItem":
		return handleGetItem(w, reqBytes)
	case "/UnaryService/Health":
		return handleHealth(w, reqBytes)
	case "/UnaryService/Echo":
		return handleEcho(w, reqBytes)

	// StreamingService methods
	case "/StreamingService/UnaryCall":
		return handleUnaryCall(w, reqBytes)
	case "/StreamingService/ServerSide":
		return handleServerSide(w, reqBytes)
	case "/StreamingService/ClientSide":
		return handleClientSide(r, w)
	case "/StreamingService/Bidirectional":
		return handleBidirectional(r, w)

	default:
		return fmt.Errorf("unknown method: %s", method)
	}
}

func handlePing(w io.Writer, reqBytes []byte) error {
	req := &pb.PingRequest{}
	if err := proto.Unmarshal(reqBytes, req); err != nil {
		return err
	}
	resp := &pb.PingResponse{Payload: req.Payload}
	respBytes, err := proto.Marshal(resp)
	if err != nil {
		return err
	}
	return rpcproto.WriteResponse(w, respBytes)
}

func handleGetItem(w io.Writer, reqBytes []byte) error {
	req := &pb.GetItemRequest{}
	if err := proto.Unmarshal(reqBytes, req); err != nil {
		return err
	}
	resp := &pb.GetItemResponse{
		Id:   req.Id,
		Name: fmt.Sprintf("item_%d", req.Id),
	}
	respBytes, err := proto.Marshal(resp)
	if err != nil {
		return err
	}
	return rpcproto.WriteResponse(w, respBytes)
}

func handleHealth(w io.Writer, reqBytes []byte) error {
	req := &pb.HealthRequest{}
	if err := proto.Unmarshal(reqBytes, req); err != nil {
		return err
	}
	resp := &pb.HealthResponse{Status: "serving"}
	respBytes, err := proto.Marshal(resp)
	if err != nil {
		return err
	}
	return rpcproto.WriteResponse(w, respBytes)
}

func handleEcho(w io.Writer, reqBytes []byte) error {
	req := &pb.EchoMessage{}
	if err := proto.Unmarshal(reqBytes, req); err != nil {
		return err
	}
	resp := &pb.EchoMessage{Text: req.Text, Code: req.Code + 1}
	respBytes, err := proto.Marshal(resp)
	if err != nil {
		return err
	}
	return rpcproto.WriteResponse(w, respBytes)
}

func handleUnaryCall(w io.Writer, reqBytes []byte) error {
	req := &pb.StreamRequest{}
	if err := proto.Unmarshal(reqBytes, req); err != nil {
		return err
	}
	resp := &pb.StreamResponse{Result: req.Query, Index: 0}
	respBytes, err := proto.Marshal(resp)
	if err != nil {
		return err
	}
	return rpcproto.WriteResponse(w, respBytes)
}

func handleServerSide(w io.Writer, reqBytes []byte) error {
	req := &pb.StreamRequest{}
	if err := proto.Unmarshal(reqBytes, req); err != nil {
		return err
	}
	for i := int32(0); i < 3; i++ {
		resp := &pb.StreamResponse{
			Result: fmt.Sprintf("%s_%d", req.Query, i),
			Index:  i,
		}
		respBytes, err := proto.Marshal(resp)
		if err != nil {
			return err
		}
		if err := rpcproto.WriteStreamMsg(w, respBytes); err != nil {
			return err
		}
	}
	return rpcproto.WriteStreamEnd(w)
}

func handleClientSide(r io.Reader, w io.Writer) error {
	count := int32(0)
	for {
		frame, err := rpcproto.ReadFrame(r)
		if err != nil {
			return err
		}
		if frame.Type == rpcproto.FrameStreamEnd {
			break
		}
		if frame.Type != rpcproto.FrameStreamMsg {
			return fmt.Errorf("expected STREAM_MSG or STREAM_END, got 0x%02x", frame.Type)
		}
		// Decode to verify it's valid, but we just count
		chunk := &pb.UploadChunk{}
		if err := proto.Unmarshal(frame.Payload, chunk); err != nil {
			return err
		}
		count++
	}
	resp := &pb.UploadResult{
		TotalChunks: count,
		Summary:     fmt.Sprintf("received_%d_chunks", count),
	}
	respBytes, err := proto.Marshal(resp)
	if err != nil {
		return err
	}
	return rpcproto.WriteResponse(w, respBytes)
}

func handleBidirectional(r io.Reader, w io.Writer) error {
	// Read all incoming messages
	var messages []*pb.ChatMessage
	for {
		frame, err := rpcproto.ReadFrame(r)
		if err != nil {
			return err
		}
		if frame.Type == rpcproto.FrameStreamEnd {
			break
		}
		if frame.Type != rpcproto.FrameStreamMsg {
			return fmt.Errorf("expected STREAM_MSG or STREAM_END, got 0x%02x", frame.Type)
		}
		msg := &pb.ChatMessage{}
		if err := proto.Unmarshal(frame.Payload, msg); err != nil {
			return err
		}
		messages = append(messages, msg)
	}

	// Echo all messages back
	for _, msg := range messages {
		echo := &pb.ChatMessage{Sender: "echo", Text: msg.Text}
		echoBytes, err := proto.Marshal(echo)
		if err != nil {
			return err
		}
		if err := rpcproto.WriteStreamMsg(w, echoBytes); err != nil {
			return err
		}
	}
	return rpcproto.WriteStreamEnd(w)
}
