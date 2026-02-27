package testcases

import "compat/pb"

func GenerateRepeated3() []TestCase {
	return []TestCase{
		{
			Name: "empty",
			Msg:  &pb.RepeatedMessage{},
		},
		{
			Name: "single",
			Msg: &pb.RepeatedMessage{
				Ints:       []int32{1},
				Strings:    []string{"hello"},
				Doubles:    []float64{1.5},
				Bools:      []bool{true},
				ByteSlices: [][]byte{{0x01}},
				Items:      []*pb.RepItem{{Id: 1, Name: "first"}},
			},
		},
		{
			Name: "multiple",
			Msg: &pb.RepeatedMessage{
				Ints:       []int32{1, 2, 3},
				Strings:    []string{"a", "b", "c"},
				Doubles:    []float64{1.1, 2.2, 3.3},
				Bools:      []bool{true, false, true},
				ByteSlices: [][]byte{{0x01}, {0x02}},
				Items: []*pb.RepItem{
					{Id: 1, Name: "one"},
					{Id: 2, Name: "two"},
				},
			},
		},
	}
}
