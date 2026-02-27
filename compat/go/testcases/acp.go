package testcases

import "compat/pb"

func GenerateAcp() []TestCase {
	return []TestCase{
		{
			Name: "empty",
			Msg:  &pb.AcpMessage{},
		},
		{
			Name: "hello",
			Msg: &pb.AcpMessage{
				Version: proto_uint32(1),
				Kind:    pb.AcpMessageKind_HELLO,
			},
		},
		{
			Name: "request_with_uri",
			Msg: &pb.AcpMessage{
				Version:   proto_uint32(1),
				Kind:      pb.AcpMessageKind_REQUEST,
				RequestId: 42,
				Uri:       proto_string("asset://textures/wood.png"),
			},
		},
		{
			Name: "discover_with_uris",
			Msg: &pb.AcpMessage{
				Kind:      pb.AcpMessageKind_DISCOVER,
				RequestId: 100,
				Uris: []string{
					"asset://models/tree.glb",
					"asset://textures/bark.png",
					"asset://shaders/pbr.wgsl",
				},
			},
		},
		{
			Name: "status_ok_with_metadata",
			Msg: &pb.AcpMessage{
				Kind:      pb.AcpMessageKind_STATUS,
				RequestId: 7,
				Status:    acpStatus(pb.AcpStatusCode_OK),
				Metadata: &pb.AcpAssetMetadata{
					Uri:         "asset://textures/wood.png",
					CachePath:   "/tmp/cache/abc123",
					PayloadHash: "sha256:deadbeef",
					FileLength:  1048576,
					UriVersion:  3,
					UpdatedAtNs: 1700000000000000000,
				},
			},
		},
		{
			Name: "status_not_found",
			Msg: &pb.AcpMessage{
				Kind:      pb.AcpMessageKind_STATUS,
				RequestId: 8,
				Status:    acpStatus(pb.AcpStatusCode_NOT_FOUND),
				Detail:    proto_string("asset not found in registry"),
			},
		},
		{
			Name: "updated_with_chunks",
			Msg: &pb.AcpMessage{
				Kind:       pb.AcpMessageKind_UPDATED,
				RequestId:  200,
				Uri:        proto_string("asset://models/character.glb"),
				ChunkIndex: 3,
				ChunkTotal: 10,
				Metadata: &pb.AcpAssetMetadata{
					Uri:         "asset://models/character.glb",
					CachePath:   "/var/cache/acp/char",
					PayloadHash: "sha256:cafebabe",
					FileLength:  5242880,
					UriVersion:  1,
					UpdatedAtNs: 1700000000500000000,
				},
			},
		},
		{
			Name: "force_recook",
			Msg: &pb.AcpMessage{
				Version:     proto_uint32(2),
				Kind:        pb.AcpMessageKind_REQUEST,
				RequestId:   99,
				Uri:         proto_string("asset://textures/grass.png"),
				ForceRecook: proto_bool(true),
			},
		},
		{
			Name: "all_status_codes",
			Msg: &pb.AcpMessage{
				Kind:   pb.AcpMessageKind_STATUS,
				Status: acpStatus(pb.AcpStatusCode_INTERNAL_ERROR),
				Detail: proto_string("unexpected codec failure"),
			},
		},
		{
			Name: "deload",
			Msg: &pb.AcpMessage{
				Kind: pb.AcpMessageKind_DELOAD,
				Uris: []string{"asset://textures/old.png"},
			},
		},
	}
}

func acpStatus(s pb.AcpStatusCode) *pb.AcpStatusCode { return &s }
