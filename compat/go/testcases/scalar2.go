package testcases

import "compat/pb"

func GenerateScalar2() []TestCase {
	return []TestCase{
		{
			Name: "all_absent",
			Msg:  &pb.Scalar2Message{},
		},
		{
			Name: "all_set",
			Msg: &pb.Scalar2Message{
				FDouble:   proto_float64(1.5),
				FFloat:    proto_float32(2.5),
				FInt32:    proto_int32(42),
				FInt64:    proto_int64(100000),
				FUint32:   proto_uint32(200),
				FUint64:   proto_uint64(300000),
				FSint32:   proto_int32(-10),
				FSint64:   proto_int64(-20000),
				FFixed32:  proto_uint32(999),
				FFixed64:  proto_uint64(888888),
				FSfixed32: proto_int32(-55),
				FSfixed64: proto_int64(-66666),
				FBool:     proto_bool(true),
				FString:   proto_string("hello"),
				FBytes:    []byte("world"),
			},
		},
	}
}

func proto_float32(v float32) *float32 { return &v }
func proto_int64(v int64) *int64       { return &v }
func proto_uint32(v uint32) *uint32    { return &v }
func proto_uint64(v uint64) *uint64    { return &v }
