package testcases

import "compat/pb"

func GenerateEnum3() []TestCase {
	return []TestCase{
		{
			Name: "default",
			Msg:  &pb.EnumMessage{},
		},
		{
			Name: "red",
			Msg: &pb.EnumMessage{
				Color: pb.Color_COLOR_RED,
				Name:  "red_test",
			},
		},
		{
			Name: "repeated",
			Msg: &pb.EnumMessage{
				Color:  pb.Color_COLOR_BLUE,
				Colors: []pb.Color{pb.Color_COLOR_RED, pb.Color_COLOR_GREEN, pb.Color_COLOR_BLUE},
				Name:   "multi",
			},
		},
	}
}
