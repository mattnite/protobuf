package testcases

import "compat/pb"

func GenerateRequired2() []TestCase {
	return []TestCase{
		{
			Name: "all_present",
			Msg: &pb.Required2Message{
				ReqId:    proto_int32(42),
				ReqName:  proto_string("required"),
				OptValue: proto_int32(10),
				OptLabel: proto_string("optional"),
			},
		},
		{
			Name: "required_only",
			Msg: &pb.Required2Message{
				ReqId:   proto_int32(1),
				ReqName: proto_string("min"),
			},
		},
	}
}
