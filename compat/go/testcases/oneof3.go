package testcases

import "compat/pb"

func GenerateOneof3() []TestCase {
	return []TestCase{
		{
			Name: "none_set",
			Msg: &pb.OneofMessage{
				Name: "empty",
			},
		},
		{
			Name: "string_variant",
			Msg: &pb.OneofMessage{
				Name:  "test",
				Value: &pb.OneofMessage_StrVal{StrVal: "hello"},
			},
		},
		{
			Name: "int_variant",
			Msg: &pb.OneofMessage{
				Name:  "test",
				Value: &pb.OneofMessage_IntVal{IntVal: 42},
			},
		},
		{
			Name: "bytes_variant",
			Msg: &pb.OneofMessage{
				Name:  "test",
				Value: &pb.OneofMessage_BytesVal{BytesVal: []byte{0x01, 0x02, 0x03}},
			},
		},
		{
			Name: "msg_variant",
			Msg: &pb.OneofMessage{
				Name: "test",
				Value: &pb.OneofMessage_MsgVal{MsgVal: &pb.SubMsg{
					Id:   1,
					Text: "sub",
				}},
			},
		},
	}
}
