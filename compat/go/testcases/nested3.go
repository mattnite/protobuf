package testcases

import "compat/pb"

func GenerateNested3() []TestCase {
	return []TestCase{
		{
			Name: "empty",
			Msg:  &pb.Outer{},
		},
		{
			Name: "two_levels",
			Msg: &pb.Outer{
				Name: "outer",
				Middle: &pb.Middle{
					Id: 10,
					Inner: &pb.Inner{
						Value: 42,
						Label: "inner_label",
					},
				},
				DirectInner: &pb.Inner{
					Value: 99,
					Label: "direct",
				},
			},
		},
		{
			Name: "single_level",
			Msg: &pb.Outer{
				DirectInner: &pb.Inner{
					Value: 5,
					Label: "only",
				},
			},
		},
	}
}
