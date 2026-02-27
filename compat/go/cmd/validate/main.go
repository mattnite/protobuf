package main

import (
	"fmt"
	"math"
	"os"
	"path/filepath"

	"compat/pb"
	"compat/testcases"

	"google.golang.org/protobuf/proto"
)

func main() {
	zigDir := filepath.Join("..", "testdata", "zig")
	failures := 0

	failures += validateFile(zigDir, "scalar3", validateScalar3)
	failures += validateFile(zigDir, "nested3", validateNested3)
	failures += validateFile(zigDir, "enum3", validateEnum3)
	failures += validateFile(zigDir, "oneof3", validateOneof3)
	failures += validateFile(zigDir, "repeated3", validateRepeated3)
	failures += validateFile(zigDir, "map3", validateMap3)
	failures += validateFile(zigDir, "optional3", validateOptional3)
	failures += validateFile(zigDir, "edge3", validateEdge3)
	failures += validateFile(zigDir, "scalar2", validateScalar2)
	failures += validateFile(zigDir, "required2", validateRequired2)
	failures += validateFile(zigDir, "acp", validateAcp)

	if failures > 0 {
		fmt.Fprintf(os.Stderr, "\n%d validation failure(s)\n", failures)
		os.Exit(1)
	}
	fmt.Println("\nAll Zig test vectors validated successfully.")
}

func validateFile(dir, name string, validate func([]testcases.RawTestCase) int) int {
	path := filepath.Join(dir, name+".bin")
	data, err := os.ReadFile(path)
	if err != nil {
		fmt.Printf("SKIP %s: %v\n", name, err)
		return 0
	}
	if len(data) == 0 {
		fmt.Printf("SKIP %s: empty file\n", name)
		return 0
	}

	cases, err := testcases.ReadTestCases(data)
	if err != nil {
		fmt.Printf("FAIL %s: framing error: %v\n", name, err)
		return 1
	}

	fmt.Printf("validating %s (%d cases)...\n", name, len(cases))
	return validate(cases)
}

func check(name, field string, ok bool) int {
	if !ok {
		fmt.Printf("  FAIL %s.%s\n", name, field)
		return 1
	}
	return 0
}

func validateScalar3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.ScalarMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "all_defaults":
			failures += check(tc.Name, "f_double", msg.FDouble == 0)
			failures += check(tc.Name, "f_int32", msg.FInt32 == 0)
			failures += check(tc.Name, "f_bool", msg.FBool == false)
		case "all_set":
			failures += check(tc.Name, "f_double", msg.FDouble == 1.5)
			failures += check(tc.Name, "f_float", msg.FFloat == 2.5)
			failures += check(tc.Name, "f_int32", msg.FInt32 == 42)
			failures += check(tc.Name, "f_int64", msg.FInt64 == 100000)
			failures += check(tc.Name, "f_uint32", msg.FUint32 == 200)
			failures += check(tc.Name, "f_uint64", msg.FUint64 == 300000)
			failures += check(tc.Name, "f_sint32", msg.FSint32 == -10)
			failures += check(tc.Name, "f_sint64", msg.FSint64 == -20000)
			failures += check(tc.Name, "f_fixed32", msg.FFixed32 == 999)
			failures += check(tc.Name, "f_fixed64", msg.FFixed64 == 888888)
			failures += check(tc.Name, "f_sfixed32", msg.FSfixed32 == -55)
			failures += check(tc.Name, "f_sfixed64", msg.FSfixed64 == -66666)
			failures += check(tc.Name, "f_bool", msg.FBool == true)
			failures += check(tc.Name, "f_string", msg.FString == "hello")
			failures += check(tc.Name, "f_bytes", string(msg.FBytes) == "world")
			failures += check(tc.Name, "f_large_tag", msg.FLargeTag == 77)
		case "max_values":
			failures += check(tc.Name, "f_int32", msg.FInt32 == math.MaxInt32)
			failures += check(tc.Name, "f_int64", msg.FInt64 == math.MaxInt64)
			failures += check(tc.Name, "f_uint32", msg.FUint32 == math.MaxUint32)
			failures += check(tc.Name, "f_uint64", msg.FUint64 == math.MaxUint64)
		case "min_values":
			failures += check(tc.Name, "f_int32", msg.FInt32 == math.MinInt32)
			failures += check(tc.Name, "f_int64", msg.FInt64 == math.MinInt64)
		case "large_tag_only":
			failures += check(tc.Name, "f_large_tag", msg.FLargeTag == 12345)
		}
	}
	return failures
}

func validateNested3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.Outer{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "empty":
			failures += check(tc.Name, "middle", msg.Middle == nil)
			failures += check(tc.Name, "direct_inner", msg.DirectInner == nil)
		case "two_levels":
			failures += check(tc.Name, "middle.id", msg.Middle != nil && msg.Middle.Id == 10)
			failures += check(tc.Name, "middle.inner.value", msg.Middle != nil && msg.Middle.Inner != nil && msg.Middle.Inner.Value == 42)
			failures += check(tc.Name, "middle.inner.label", msg.Middle != nil && msg.Middle.Inner != nil && msg.Middle.Inner.Label == "inner_label")
			failures += check(tc.Name, "direct_inner.value", msg.DirectInner != nil && msg.DirectInner.Value == 99)
			failures += check(tc.Name, "direct_inner.label", msg.DirectInner != nil && msg.DirectInner.Label == "direct")
			failures += check(tc.Name, "name", msg.Name == "outer")
		case "single_level":
			failures += check(tc.Name, "middle", msg.Middle == nil)
			failures += check(tc.Name, "direct_inner.value", msg.DirectInner != nil && msg.DirectInner.Value == 5)
			failures += check(tc.Name, "direct_inner.label", msg.DirectInner != nil && msg.DirectInner.Label == "only")
		}
	}
	return failures
}

func validateEnum3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.EnumMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "default":
			failures += check(tc.Name, "color", msg.Color == pb.Color_COLOR_UNSPECIFIED)
		case "red":
			failures += check(tc.Name, "color", msg.Color == pb.Color_COLOR_RED)
			failures += check(tc.Name, "name", msg.Name == "red_test")
		case "repeated":
			failures += check(tc.Name, "color", msg.Color == pb.Color_COLOR_BLUE)
			failures += check(tc.Name, "colors.len", len(msg.Colors) == 3)
			if len(msg.Colors) == 3 {
				failures += check(tc.Name, "colors[0]", msg.Colors[0] == pb.Color_COLOR_RED)
				failures += check(tc.Name, "colors[1]", msg.Colors[1] == pb.Color_COLOR_GREEN)
				failures += check(tc.Name, "colors[2]", msg.Colors[2] == pb.Color_COLOR_BLUE)
			}
			failures += check(tc.Name, "name", msg.Name == "multi")
		}
	}
	return failures
}

func validateOneof3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.OneofMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "none_set":
			failures += check(tc.Name, "name", msg.Name == "empty")
			failures += check(tc.Name, "value", msg.Value == nil)
		case "string_variant":
			failures += check(tc.Name, "name", msg.Name == "test")
			if v, ok := msg.Value.(*pb.OneofMessage_StrVal); ok {
				failures += check(tc.Name, "str_val", v.StrVal == "hello")
			} else {
				failures += check(tc.Name, "value_type", false)
			}
		case "int_variant":
			failures += check(tc.Name, "name", msg.Name == "test")
			if v, ok := msg.Value.(*pb.OneofMessage_IntVal); ok {
				failures += check(tc.Name, "int_val", v.IntVal == 42)
			} else {
				failures += check(tc.Name, "value_type", false)
			}
		case "bytes_variant":
			failures += check(tc.Name, "name", msg.Name == "test")
			if v, ok := msg.Value.(*pb.OneofMessage_BytesVal); ok {
				failures += check(tc.Name, "bytes_val", len(v.BytesVal) == 3 && v.BytesVal[0] == 0x01 && v.BytesVal[1] == 0x02 && v.BytesVal[2] == 0x03)
			} else {
				failures += check(tc.Name, "value_type", false)
			}
		case "msg_variant":
			failures += check(tc.Name, "name", msg.Name == "test")
			if v, ok := msg.Value.(*pb.OneofMessage_MsgVal); ok {
				failures += check(tc.Name, "msg_val.id", v.MsgVal != nil && v.MsgVal.Id == 1)
				failures += check(tc.Name, "msg_val.text", v.MsgVal != nil && v.MsgVal.Text == "sub")
			} else {
				failures += check(tc.Name, "value_type", false)
			}
		}
	}
	return failures
}

func validateOptional3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.OptionalMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "all_unset":
			failures += check(tc.Name, "opt_int", msg.OptInt == nil)
			failures += check(tc.Name, "opt_str", msg.OptStr == nil)
			failures += check(tc.Name, "opt_bool", msg.OptBool == nil)
			failures += check(tc.Name, "opt_double", msg.OptDouble == nil)
		case "all_zero":
			failures += check(tc.Name, "opt_int", msg.OptInt != nil && *msg.OptInt == 0)
			failures += check(tc.Name, "opt_bool", msg.OptBool != nil && *msg.OptBool == false)
			failures += check(tc.Name, "opt_double", msg.OptDouble != nil && *msg.OptDouble == 0.0)
		case "all_nonzero":
			failures += check(tc.Name, "opt_int", msg.OptInt != nil && *msg.OptInt == 42)
			failures += check(tc.Name, "opt_str", msg.OptStr != nil && *msg.OptStr == "hello")
			failures += check(tc.Name, "opt_bool", msg.OptBool != nil && *msg.OptBool == true)
			failures += check(tc.Name, "opt_double", msg.OptDouble != nil && *msg.OptDouble == 3.14)
			failures += check(tc.Name, "regular_int", msg.RegularInt == 100)
		}
	}
	return failures
}

func validateEdge3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.EdgeMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "special_floats":
			failures += check(tc.Name, "f_nan", math.IsNaN(msg.FNan))
			failures += check(tc.Name, "f_pos_inf", math.IsInf(msg.FPosInf, 1))
			failures += check(tc.Name, "f_neg_inf", math.IsInf(msg.FNegInf, -1))
		case "extreme_ints":
			failures += check(tc.Name, "f_max_int32", msg.FMaxInt32 == math.MaxInt32)
			failures += check(tc.Name, "f_min_int32", msg.FMinInt32 == math.MinInt32)
			failures += check(tc.Name, "f_max_int64", msg.FMaxInt64 == math.MaxInt64)
			failures += check(tc.Name, "f_min_int64", msg.FMinInt64 == math.MinInt64)
			failures += check(tc.Name, "f_max_uint32", msg.FMaxUint32 == math.MaxUint32)
			failures += check(tc.Name, "f_max_uint64", msg.FMaxUint64 == math.MaxUint64)
		case "unicode_and_binary":
			failures += check(tc.Name, "f_unicode", msg.FUnicode == "hello \xc3\xa9\xc3\xa0\xc3\xbc \xe4\xb8\x96\xe7\x95\x8c")
			failures += check(tc.Name, "f_binary.len", len(msg.FBinary) == 6)
			if len(msg.FBinary) == 6 {
				failures += check(tc.Name, "f_binary", msg.FBinary[0] == 0x00 && msg.FBinary[1] == 0x01 && msg.FBinary[2] == 0x02 && msg.FBinary[3] == 0xff && msg.FBinary[4] == 0xfe && msg.FBinary[5] == 0xfd)
			}
		}
	}
	return failures
}

func validateScalar2(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.Scalar2Message{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "all_absent":
			failures += check(tc.Name, "f_double", msg.FDouble == nil)
			failures += check(tc.Name, "f_int32", msg.FInt32 == nil)
			failures += check(tc.Name, "f_string", msg.FString == nil)
		case "all_set":
			failures += check(tc.Name, "f_double", msg.FDouble != nil && *msg.FDouble == 1.5)
			failures += check(tc.Name, "f_float", msg.FFloat != nil && *msg.FFloat == 2.5)
			failures += check(tc.Name, "f_int32", msg.FInt32 != nil && *msg.FInt32 == 42)
			failures += check(tc.Name, "f_int64", msg.FInt64 != nil && *msg.FInt64 == 100000)
			failures += check(tc.Name, "f_uint32", msg.FUint32 != nil && *msg.FUint32 == 200)
			failures += check(tc.Name, "f_uint64", msg.FUint64 != nil && *msg.FUint64 == 300000)
			failures += check(tc.Name, "f_sint32", msg.FSint32 != nil && *msg.FSint32 == -10)
			failures += check(tc.Name, "f_sint64", msg.FSint64 != nil && *msg.FSint64 == -20000)
			failures += check(tc.Name, "f_fixed32", msg.FFixed32 != nil && *msg.FFixed32 == 999)
			failures += check(tc.Name, "f_fixed64", msg.FFixed64 != nil && *msg.FFixed64 == 888888)
			failures += check(tc.Name, "f_sfixed32", msg.FSfixed32 != nil && *msg.FSfixed32 == -55)
			failures += check(tc.Name, "f_sfixed64", msg.FSfixed64 != nil && *msg.FSfixed64 == -66666)
			failures += check(tc.Name, "f_bool", msg.FBool != nil && *msg.FBool == true)
			failures += check(tc.Name, "f_string", msg.FString != nil && *msg.FString == "hello")
			failures += check(tc.Name, "f_bytes", string(msg.FBytes) == "world")
		}
	}
	return failures
}

func validateRepeated3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.RepeatedMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "empty":
			failures += check(tc.Name, "ints.len", len(msg.Ints) == 0)
			failures += check(tc.Name, "strings.len", len(msg.Strings) == 0)
			failures += check(tc.Name, "doubles.len", len(msg.Doubles) == 0)
			failures += check(tc.Name, "bools.len", len(msg.Bools) == 0)
			failures += check(tc.Name, "byte_slices.len", len(msg.ByteSlices) == 0)
			failures += check(tc.Name, "items.len", len(msg.Items) == 0)
		case "single":
			failures += check(tc.Name, "ints.len", len(msg.Ints) == 1)
			if len(msg.Ints) == 1 {
				failures += check(tc.Name, "ints[0]", msg.Ints[0] == 1)
			}
			failures += check(tc.Name, "strings.len", len(msg.Strings) == 1)
			if len(msg.Strings) == 1 {
				failures += check(tc.Name, "strings[0]", msg.Strings[0] == "hello")
			}
			failures += check(tc.Name, "doubles.len", len(msg.Doubles) == 1)
			if len(msg.Doubles) == 1 {
				failures += check(tc.Name, "doubles[0]", msg.Doubles[0] == 1.5)
			}
			failures += check(tc.Name, "bools.len", len(msg.Bools) == 1)
			if len(msg.Bools) == 1 {
				failures += check(tc.Name, "bools[0]", msg.Bools[0] == true)
			}
			failures += check(tc.Name, "byte_slices.len", len(msg.ByteSlices) == 1)
			if len(msg.ByteSlices) == 1 {
				failures += check(tc.Name, "byte_slices[0]", len(msg.ByteSlices[0]) == 1 && msg.ByteSlices[0][0] == 0x01)
			}
			failures += check(tc.Name, "items.len", len(msg.Items) == 1)
			if len(msg.Items) == 1 {
				failures += check(tc.Name, "items[0].id", msg.Items[0].Id == 1)
				failures += check(tc.Name, "items[0].name", msg.Items[0].Name == "first")
			}
		case "multiple":
			failures += check(tc.Name, "ints.len", len(msg.Ints) == 3)
			if len(msg.Ints) == 3 {
				failures += check(tc.Name, "ints[0]", msg.Ints[0] == 1)
				failures += check(tc.Name, "ints[1]", msg.Ints[1] == 2)
				failures += check(tc.Name, "ints[2]", msg.Ints[2] == 3)
			}
			failures += check(tc.Name, "strings.len", len(msg.Strings) == 3)
			if len(msg.Strings) == 3 {
				failures += check(tc.Name, "strings[0]", msg.Strings[0] == "a")
				failures += check(tc.Name, "strings[1]", msg.Strings[1] == "b")
				failures += check(tc.Name, "strings[2]", msg.Strings[2] == "c")
			}
			failures += check(tc.Name, "doubles.len", len(msg.Doubles) == 3)
			failures += check(tc.Name, "bools.len", len(msg.Bools) == 3)
			if len(msg.Bools) == 3 {
				failures += check(tc.Name, "bools[0]", msg.Bools[0] == true)
				failures += check(tc.Name, "bools[1]", msg.Bools[1] == false)
				failures += check(tc.Name, "bools[2]", msg.Bools[2] == true)
			}
			failures += check(tc.Name, "byte_slices.len", len(msg.ByteSlices) == 2)
			failures += check(tc.Name, "items.len", len(msg.Items) == 2)
			if len(msg.Items) == 2 {
				failures += check(tc.Name, "items[0].id", msg.Items[0].Id == 1)
				failures += check(tc.Name, "items[0].name", msg.Items[0].Name == "one")
				failures += check(tc.Name, "items[1].id", msg.Items[1].Id == 2)
				failures += check(tc.Name, "items[1].name", msg.Items[1].Name == "two")
			}
		}
	}
	return failures
}

func validateMap3(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.MapMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "empty":
			failures += check(tc.Name, "str_str.len", len(msg.StrStr) == 0)
			failures += check(tc.Name, "int_str.len", len(msg.IntStr) == 0)
			failures += check(tc.Name, "str_msg.len", len(msg.StrMsg) == 0)
		case "single":
			failures += check(tc.Name, "str_str.len", len(msg.StrStr) == 1)
			failures += check(tc.Name, "str_str[key]", msg.StrStr["key"] == "val")
			failures += check(tc.Name, "int_str.len", len(msg.IntStr) == 1)
			failures += check(tc.Name, "int_str[1]", msg.IntStr[1] == "one")
			failures += check(tc.Name, "str_msg.len", len(msg.StrMsg) == 1)
			if sub, ok := msg.StrMsg["a"]; ok {
				failures += check(tc.Name, "str_msg[a].id", sub.Id == 1)
				failures += check(tc.Name, "str_msg[a].text", sub.Text == "alpha")
			} else {
				failures += check(tc.Name, "str_msg[a]", false)
			}
		case "multiple":
			failures += check(tc.Name, "str_str.len", len(msg.StrStr) == 2)
			failures += check(tc.Name, "str_str[a]", msg.StrStr["a"] == "1")
			failures += check(tc.Name, "str_str[b]", msg.StrStr["b"] == "2")
			failures += check(tc.Name, "int_str.len", len(msg.IntStr) == 2)
			failures += check(tc.Name, "int_str[1]", msg.IntStr[1] == "one")
			failures += check(tc.Name, "int_str[2]", msg.IntStr[2] == "two")
			failures += check(tc.Name, "str_msg.len", len(msg.StrMsg) == 2)
			if sub, ok := msg.StrMsg["x"]; ok {
				failures += check(tc.Name, "str_msg[x].id", sub.Id == 10)
				failures += check(tc.Name, "str_msg[x].text", sub.Text == "x")
			} else {
				failures += check(tc.Name, "str_msg[x]", false)
			}
			if sub, ok := msg.StrMsg["y"]; ok {
				failures += check(tc.Name, "str_msg[y].id", sub.Id == 20)
				failures += check(tc.Name, "str_msg[y].text", sub.Text == "y")
			} else {
				failures += check(tc.Name, "str_msg[y]", false)
			}
		}
	}
	return failures
}

func validateRequired2(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.Required2Message{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "all_present":
			failures += check(tc.Name, "req_id", msg.ReqId != nil && *msg.ReqId == 42)
			failures += check(tc.Name, "req_name", msg.ReqName != nil && *msg.ReqName == "required")
			failures += check(tc.Name, "opt_value", msg.OptValue != nil && *msg.OptValue == 10)
			failures += check(tc.Name, "opt_label", msg.OptLabel != nil && *msg.OptLabel == "optional")
		case "required_only":
			failures += check(tc.Name, "req_id", msg.ReqId != nil && *msg.ReqId == 1)
			failures += check(tc.Name, "req_name", msg.ReqName != nil && *msg.ReqName == "min")
			failures += check(tc.Name, "opt_value", msg.OptValue == nil)
			failures += check(tc.Name, "opt_label", msg.OptLabel == nil)
		}
	}
	return failures
}

func validateAcp(cases []testcases.RawTestCase) int {
	failures := 0
	for _, tc := range cases {
		msg := &pb.AcpMessage{}
		if err := proto.Unmarshal(tc.Data, msg); err != nil {
			fmt.Printf("  FAIL %s: unmarshal: %v\n", tc.Name, err)
			failures++
			continue
		}

		switch tc.Name {
		case "empty":
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_HELLO)
			failures += check(tc.Name, "request_id", msg.RequestId == 0)
		case "hello":
			failures += check(tc.Name, "version", msg.Version != nil && *msg.Version == 1)
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_HELLO)
		case "request_with_uri":
			failures += check(tc.Name, "version", msg.Version != nil && *msg.Version == 1)
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_REQUEST)
			failures += check(tc.Name, "request_id", msg.RequestId == 42)
			failures += check(tc.Name, "uri", msg.Uri != nil && *msg.Uri == "asset://textures/wood.png")
		case "discover_with_uris":
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_DISCOVER)
			failures += check(tc.Name, "request_id", msg.RequestId == 100)
			failures += check(tc.Name, "uris.len", len(msg.Uris) == 3)
			if len(msg.Uris) == 3 {
				failures += check(tc.Name, "uris[0]", msg.Uris[0] == "asset://models/tree.glb")
				failures += check(tc.Name, "uris[1]", msg.Uris[1] == "asset://textures/bark.png")
				failures += check(tc.Name, "uris[2]", msg.Uris[2] == "asset://shaders/pbr.wgsl")
			}
		case "status_ok_with_metadata":
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_STATUS)
			failures += check(tc.Name, "status", msg.Status != nil && *msg.Status == pb.AcpStatusCode_OK)
			failures += check(tc.Name, "metadata", msg.Metadata != nil)
			if msg.Metadata != nil {
				failures += check(tc.Name, "metadata.uri", msg.Metadata.Uri == "asset://textures/wood.png")
				failures += check(tc.Name, "metadata.cache_path", msg.Metadata.CachePath == "/tmp/cache/abc123")
				failures += check(tc.Name, "metadata.payload_hash", msg.Metadata.PayloadHash == "sha256:deadbeef")
				failures += check(tc.Name, "metadata.file_length", msg.Metadata.FileLength == 1048576)
				failures += check(tc.Name, "metadata.uri_version", msg.Metadata.UriVersion == 3)
				failures += check(tc.Name, "metadata.updated_at_ns", msg.Metadata.UpdatedAtNs == 1700000000000000000)
			}
		case "status_not_found":
			failures += check(tc.Name, "status", msg.Status != nil && *msg.Status == pb.AcpStatusCode_NOT_FOUND)
			failures += check(tc.Name, "detail", msg.Detail != nil && *msg.Detail == "asset not found in registry")
		case "updated_with_chunks":
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_UPDATED)
			failures += check(tc.Name, "chunk_index", msg.ChunkIndex == 3)
			failures += check(tc.Name, "chunk_total", msg.ChunkTotal == 10)
			failures += check(tc.Name, "metadata", msg.Metadata != nil)
		case "force_recook":
			failures += check(tc.Name, "version", msg.Version != nil && *msg.Version == 2)
			failures += check(tc.Name, "force_recook", msg.ForceRecook != nil && *msg.ForceRecook == true)
			failures += check(tc.Name, "uri", msg.Uri != nil && *msg.Uri == "asset://textures/grass.png")
		case "all_status_codes":
			failures += check(tc.Name, "status", msg.Status != nil && *msg.Status == pb.AcpStatusCode_INTERNAL_ERROR)
			failures += check(tc.Name, "detail", msg.Detail != nil && *msg.Detail == "unexpected codec failure")
		case "deload":
			failures += check(tc.Name, "kind", msg.Kind == pb.AcpMessageKind_DELOAD)
			failures += check(tc.Name, "uris.len", len(msg.Uris) == 1)
		}
	}
	return failures
}
