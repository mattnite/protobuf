package testcases

import (
	"math"

	"compat/pb"
)

func GenerateScalar3() []TestCase {
	return []TestCase{
		{
			Name: "all_defaults",
			Msg:  &pb.ScalarMessage{},
		},
		{
			Name: "all_set",
			Msg: &pb.ScalarMessage{
				FDouble:   1.5,
				FFloat:    2.5,
				FInt32:    42,
				FInt64:    100000,
				FUint32:   200,
				FUint64:   300000,
				FSint32:   -10,
				FSint64:   -20000,
				FFixed32:  999,
				FFixed64:  888888,
				FSfixed32: -55,
				FSfixed64: -66666,
				FBool:     true,
				FString:   "hello",
				FBytes:    []byte("world"),
				FLargeTag: 77,
			},
		},
		{
			Name: "max_values",
			Msg: &pb.ScalarMessage{
				FInt32:  math.MaxInt32,
				FInt64:  math.MaxInt64,
				FUint32: math.MaxUint32,
				FUint64: math.MaxUint64,
				FDouble: 1.7976931348623157e+308,
				FString: "a long string value for testing purposes",
			},
		},
		{
			Name: "min_values",
			Msg: &pb.ScalarMessage{
				FInt32:  math.MinInt32,
				FInt64:  math.MinInt64,
				FDouble: -1.7976931348623157e+308,
				FFloat:  -3.4028235e+38,
			},
		},
		{
			Name: "large_tag_only",
			Msg: &pb.ScalarMessage{
				FLargeTag: 12345,
			},
		},
	}
}
