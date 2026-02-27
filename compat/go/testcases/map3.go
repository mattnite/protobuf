package testcases

import "compat/pb"

func GenerateMap3() []TestCase {
	return []TestCase{
		{
			Name: "empty",
			Msg:  &pb.MapMessage{},
		},
		{
			Name: "single",
			Msg: &pb.MapMessage{
				StrStr: map[string]string{"key": "val"},
				IntStr: map[int32]string{1: "one"},
				StrMsg: map[string]*pb.MapSubMsg{
					"a": {Id: 1, Text: "alpha"},
				},
			},
		},
		{
			Name: "multiple",
			Msg: &pb.MapMessage{
				StrStr: map[string]string{"a": "1", "b": "2"},
				IntStr: map[int32]string{1: "one", 2: "two"},
				StrMsg: map[string]*pb.MapSubMsg{
					"x": {Id: 10, Text: "x"},
					"y": {Id: 20, Text: "y"},
				},
			},
		},
	}
}
