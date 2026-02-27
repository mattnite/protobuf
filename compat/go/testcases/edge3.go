package testcases

import (
	"math"

	"compat/pb"
)

func GenerateEdge3() []TestCase {
	return []TestCase{
		{
			Name: "special_floats",
			Msg: &pb.EdgeMessage{
				FNan:    math.NaN(),
				FPosInf: math.Inf(1),
				FNegInf: math.Inf(-1),
			},
		},
		{
			Name: "extreme_ints",
			Msg: &pb.EdgeMessage{
				FMaxInt32:  math.MaxInt32,
				FMinInt32:  math.MinInt32,
				FMaxInt64:  math.MaxInt64,
				FMinInt64:  math.MinInt64,
				FMaxUint32: math.MaxUint32,
				FMaxUint64: math.MaxUint64,
			},
		},
		{
			Name: "unicode_and_binary",
			Msg: &pb.EdgeMessage{
				FUnicode: "hello \xc3\xa9\xc3\xa0\xc3\xbc \xe4\xb8\x96\xe7\x95\x8c",
				FBinary:  []byte{0x00, 0x01, 0x02, 0xff, 0xfe, 0xfd},
			},
		},
	}
}
