package testcases

import "compat/pb"

func GenerateOptional3() []TestCase {
	return []TestCase{
		{
			Name: "all_unset",
			Msg:  &pb.OptionalMessage{},
		},
		{
			Name: "all_zero",
			Msg: &pb.OptionalMessage{
				OptInt:    proto_int32(0),
				OptStr:    proto_string(""),
				OptBool:   proto_bool(false),
				OptDouble: proto_float64(0.0),
			},
		},
		{
			Name: "all_nonzero",
			Msg: &pb.OptionalMessage{
				OptInt:     proto_int32(42),
				OptStr:     proto_string("hello"),
				OptBool:    proto_bool(true),
				OptDouble:  proto_float64(3.14),
				RegularInt: 100,
			},
		},
	}
}

func proto_int32(v int32) *int32     { return &v }
func proto_string(v string) *string  { return &v }
func proto_bool(v bool) *bool        { return &v }
func proto_float64(v float64) *float64 { return &v }
