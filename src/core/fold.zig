const std = @import("std");

const Allocator = std.mem.Allocator;

pub const boundary_before = " \t/-_.:?&=#,;+~@";

pub const Text = struct {
    bytes: []const u8,
    starts: []const u8,

    pub fn find(self: Text, wanted: u8, from: usize) ?usize {
        if (from >= self.bytes.len) return null;
        return std.mem.findScalarPos(u8, self.bytes, from, wanted);
    }

    pub fn boundary(self: Text, at: usize) bool {
        return self.starts[at >> 3] & bit(at) != 0;
    }
};

pub const Folded = struct {
    text: Text,
    plain: Text,
};

const Range = struct {
    first: u21,
    last: u21,
    delta: i32,
    every: u21,
};

const ranges = [_]Range{
    .{ .first = 0x00C0, .last = 0x00D6, .delta = 32, .every = 1 },
    .{ .first = 0x00D8, .last = 0x00DE, .delta = 32, .every = 1 },
    .{ .first = 0x0100, .last = 0x012E, .delta = 1, .every = 2 },
    .{ .first = 0x0130, .last = 0x0130, .delta = -199, .every = 1 },
    .{ .first = 0x0132, .last = 0x0136, .delta = 1, .every = 2 },
    .{ .first = 0x0139, .last = 0x0147, .delta = 1, .every = 2 },
    .{ .first = 0x014A, .last = 0x0176, .delta = 1, .every = 2 },
    .{ .first = 0x0178, .last = 0x0178, .delta = -121, .every = 1 },
    .{ .first = 0x0179, .last = 0x017D, .delta = 1, .every = 2 },
    .{ .first = 0x0181, .last = 0x0181, .delta = 210, .every = 1 },
    .{ .first = 0x0182, .last = 0x0184, .delta = 1, .every = 2 },
    .{ .first = 0x0186, .last = 0x0186, .delta = 206, .every = 1 },
    .{ .first = 0x0187, .last = 0x0187, .delta = 1, .every = 1 },
    .{ .first = 0x0189, .last = 0x018A, .delta = 205, .every = 1 },
    .{ .first = 0x018B, .last = 0x018B, .delta = 1, .every = 1 },
    .{ .first = 0x018E, .last = 0x018E, .delta = 79, .every = 1 },
    .{ .first = 0x018F, .last = 0x018F, .delta = 202, .every = 1 },
    .{ .first = 0x0190, .last = 0x0190, .delta = 203, .every = 1 },
    .{ .first = 0x0191, .last = 0x0191, .delta = 1, .every = 1 },
    .{ .first = 0x0193, .last = 0x0193, .delta = 205, .every = 1 },
    .{ .first = 0x0194, .last = 0x0194, .delta = 207, .every = 1 },
    .{ .first = 0x0196, .last = 0x0196, .delta = 211, .every = 1 },
    .{ .first = 0x0197, .last = 0x0197, .delta = 209, .every = 1 },
    .{ .first = 0x0198, .last = 0x0198, .delta = 1, .every = 1 },
    .{ .first = 0x019C, .last = 0x019C, .delta = 211, .every = 1 },
    .{ .first = 0x019D, .last = 0x019D, .delta = 213, .every = 1 },
    .{ .first = 0x019F, .last = 0x019F, .delta = 214, .every = 1 },
    .{ .first = 0x01A0, .last = 0x01A4, .delta = 1, .every = 2 },
    .{ .first = 0x01A6, .last = 0x01A6, .delta = 218, .every = 1 },
    .{ .first = 0x01A7, .last = 0x01A7, .delta = 1, .every = 1 },
    .{ .first = 0x01A9, .last = 0x01A9, .delta = 218, .every = 1 },
    .{ .first = 0x01AC, .last = 0x01AC, .delta = 1, .every = 1 },
    .{ .first = 0x01AE, .last = 0x01AE, .delta = 218, .every = 1 },
    .{ .first = 0x01AF, .last = 0x01AF, .delta = 1, .every = 1 },
    .{ .first = 0x01B1, .last = 0x01B2, .delta = 217, .every = 1 },
    .{ .first = 0x01B3, .last = 0x01B5, .delta = 1, .every = 2 },
    .{ .first = 0x01B7, .last = 0x01B7, .delta = 219, .every = 1 },
    .{ .first = 0x01B8, .last = 0x01B8, .delta = 1, .every = 1 },
    .{ .first = 0x01BC, .last = 0x01BC, .delta = 1, .every = 1 },
    .{ .first = 0x01C4, .last = 0x01C4, .delta = 2, .every = 1 },
    .{ .first = 0x01C5, .last = 0x01C5, .delta = 1, .every = 1 },
    .{ .first = 0x01C7, .last = 0x01C7, .delta = 2, .every = 1 },
    .{ .first = 0x01C8, .last = 0x01C8, .delta = 1, .every = 1 },
    .{ .first = 0x01CA, .last = 0x01CA, .delta = 2, .every = 1 },
    .{ .first = 0x01CB, .last = 0x01DB, .delta = 1, .every = 2 },
    .{ .first = 0x01DE, .last = 0x01EE, .delta = 1, .every = 2 },
    .{ .first = 0x01F1, .last = 0x01F1, .delta = 2, .every = 1 },
    .{ .first = 0x01F2, .last = 0x01F4, .delta = 1, .every = 2 },
    .{ .first = 0x01F6, .last = 0x01F6, .delta = -97, .every = 1 },
    .{ .first = 0x01F7, .last = 0x01F7, .delta = -56, .every = 1 },
    .{ .first = 0x01F8, .last = 0x021E, .delta = 1, .every = 2 },
    .{ .first = 0x0220, .last = 0x0220, .delta = -130, .every = 1 },
    .{ .first = 0x0222, .last = 0x0232, .delta = 1, .every = 2 },
    .{ .first = 0x023A, .last = 0x023A, .delta = 10795, .every = 1 },
    .{ .first = 0x023B, .last = 0x023B, .delta = 1, .every = 1 },
    .{ .first = 0x023D, .last = 0x023D, .delta = -163, .every = 1 },
    .{ .first = 0x023E, .last = 0x023E, .delta = 10792, .every = 1 },
    .{ .first = 0x0241, .last = 0x0241, .delta = 1, .every = 1 },
    .{ .first = 0x0243, .last = 0x0243, .delta = -195, .every = 1 },
    .{ .first = 0x0244, .last = 0x0244, .delta = 69, .every = 1 },
    .{ .first = 0x0245, .last = 0x0245, .delta = 71, .every = 1 },
    .{ .first = 0x0246, .last = 0x024E, .delta = 1, .every = 2 },
    .{ .first = 0x0370, .last = 0x0372, .delta = 1, .every = 2 },
    .{ .first = 0x0376, .last = 0x0376, .delta = 1, .every = 1 },
    .{ .first = 0x037F, .last = 0x037F, .delta = 116, .every = 1 },
    .{ .first = 0x0386, .last = 0x0386, .delta = 38, .every = 1 },
    .{ .first = 0x0388, .last = 0x038A, .delta = 37, .every = 1 },
    .{ .first = 0x038C, .last = 0x038C, .delta = 64, .every = 1 },
    .{ .first = 0x038E, .last = 0x038F, .delta = 63, .every = 1 },
    .{ .first = 0x0391, .last = 0x03A1, .delta = 32, .every = 1 },
    .{ .first = 0x03A3, .last = 0x03AB, .delta = 32, .every = 1 },
    .{ .first = 0x03CF, .last = 0x03CF, .delta = 8, .every = 1 },
    .{ .first = 0x03D8, .last = 0x03EE, .delta = 1, .every = 2 },
    .{ .first = 0x03F4, .last = 0x03F4, .delta = -60, .every = 1 },
    .{ .first = 0x03F7, .last = 0x03F7, .delta = 1, .every = 1 },
    .{ .first = 0x03F9, .last = 0x03F9, .delta = -7, .every = 1 },
    .{ .first = 0x03FA, .last = 0x03FA, .delta = 1, .every = 1 },
    .{ .first = 0x03FD, .last = 0x03FF, .delta = -130, .every = 1 },
    .{ .first = 0x0400, .last = 0x040F, .delta = 80, .every = 1 },
    .{ .first = 0x0410, .last = 0x042F, .delta = 32, .every = 1 },
    .{ .first = 0x0460, .last = 0x0480, .delta = 1, .every = 2 },
    .{ .first = 0x048A, .last = 0x04BE, .delta = 1, .every = 2 },
    .{ .first = 0x04C0, .last = 0x04C0, .delta = 15, .every = 1 },
    .{ .first = 0x04C1, .last = 0x04CD, .delta = 1, .every = 2 },
    .{ .first = 0x04D0, .last = 0x052E, .delta = 1, .every = 2 },
    .{ .first = 0x1E00, .last = 0x1E94, .delta = 1, .every = 2 },
    .{ .first = 0x1E9E, .last = 0x1E9E, .delta = -7615, .every = 1 },
    .{ .first = 0x1EA0, .last = 0x1EFE, .delta = 1, .every = 2 },
    .{ .first = 0x1F08, .last = 0x1F0F, .delta = -8, .every = 1 },
    .{ .first = 0x1F18, .last = 0x1F1D, .delta = -8, .every = 1 },
    .{ .first = 0x1F28, .last = 0x1F2F, .delta = -8, .every = 1 },
    .{ .first = 0x1F38, .last = 0x1F3F, .delta = -8, .every = 1 },
    .{ .first = 0x1F48, .last = 0x1F4D, .delta = -8, .every = 1 },
    .{ .first = 0x1F59, .last = 0x1F5F, .delta = -8, .every = 2 },
    .{ .first = 0x1F68, .last = 0x1F6F, .delta = -8, .every = 1 },
    .{ .first = 0x1F88, .last = 0x1F8F, .delta = -8, .every = 1 },
    .{ .first = 0x1F98, .last = 0x1F9F, .delta = -8, .every = 1 },
    .{ .first = 0x1FA8, .last = 0x1FAF, .delta = -8, .every = 1 },
    .{ .first = 0x1FB8, .last = 0x1FB9, .delta = -8, .every = 1 },
    .{ .first = 0x1FBA, .last = 0x1FBB, .delta = -74, .every = 1 },
    .{ .first = 0x1FBC, .last = 0x1FBC, .delta = -9, .every = 1 },
    .{ .first = 0x1FC8, .last = 0x1FCB, .delta = -86, .every = 1 },
    .{ .first = 0x1FCC, .last = 0x1FCC, .delta = -9, .every = 1 },
    .{ .first = 0x1FD8, .last = 0x1FD9, .delta = -8, .every = 1 },
    .{ .first = 0x1FDA, .last = 0x1FDB, .delta = -100, .every = 1 },
    .{ .first = 0x1FE8, .last = 0x1FE9, .delta = -8, .every = 1 },
    .{ .first = 0x1FEA, .last = 0x1FEB, .delta = -112, .every = 1 },
    .{ .first = 0x1FEC, .last = 0x1FEC, .delta = -7, .every = 1 },
    .{ .first = 0x1FF8, .last = 0x1FF9, .delta = -128, .every = 1 },
    .{ .first = 0x1FFA, .last = 0x1FFB, .delta = -126, .every = 1 },
    .{ .first = 0x1FFC, .last = 0x1FFC, .delta = -9, .every = 1 },
};

const plains = [_]struct { u21, u8 }{
    .{ 0x00C0, 'a' }, .{ 0x00C1, 'a' },  .{ 0x00C2, 'a' },  .{ 0x00C3, 'a' }, .{ 0x00C4, 'a' }, .{ 0x00C5, 'a' },
    .{ 0x00C7, 'c' }, .{ 0x00C8, 'e' },  .{ 0x00C9, 'e' },  .{ 0x00CA, 'e' }, .{ 0x00CB, 'e' }, .{ 0x00CC, 'i' },
    .{ 0x00CD, 'i' }, .{ 0x00CE, 'i' },  .{ 0x00CF, 'i' },  .{ 0x00D1, 'n' }, .{ 0x00D2, 'o' }, .{ 0x00D3, 'o' },
    .{ 0x00D4, 'o' }, .{ 0x00D5, 'o' },  .{ 0x00D6, 'o' },  .{ 0x00D8, 'o' }, .{ 0x00D9, 'u' }, .{ 0x00DA, 'u' },
    .{ 0x00DB, 'u' }, .{ 0x00DC, 'u' },  .{ 0x00DD, 'y' },  .{ 0x00DF, 's' }, .{ 0x00E0, 'a' }, .{ 0x00E1, 'a' },
    .{ 0x00E2, 'a' }, .{ 0x00E3, 'a' },  .{ 0x00E4, 'a' },  .{ 0x00E5, 'a' }, .{ 0x00E7, 'c' }, .{ 0x00E8, 'e' },
    .{ 0x00E9, 'e' }, .{ 0x00EA, 'e' },  .{ 0x00EB, 'e' },  .{ 0x00EC, 'i' }, .{ 0x00ED, 'i' }, .{ 0x00EE, 'i' },
    .{ 0x00EF, 'i' }, .{ 0x00F1, 'n' },  .{ 0x00F2, 'o' },  .{ 0x00F3, 'o' }, .{ 0x00F4, 'o' }, .{ 0x00F5, 'o' },
    .{ 0x00F6, 'o' }, .{ 0x00F8, 'o' },  .{ 0x00F9, 'u' },  .{ 0x00FA, 'u' }, .{ 0x00FB, 'u' }, .{ 0x00FC, 'u' },
    .{ 0x00FD, 'y' }, .{ 0x00FF, 'y' },  .{ 0x0101, 'a' },  .{ 0x0103, 'a' }, .{ 0x0105, 'a' }, .{ 0x0107, 'c' },
    .{ 0x0109, 'c' }, .{ 0x010B, 'c' },  .{ 0x010D, 'c' },  .{ 0x010F, 'd' }, .{ 0x0111, 'd' }, .{ 0x0113, 'e' },
    .{ 0x0115, 'e' }, .{ 0x0117, 'e' },  .{ 0x0119, 'e' },  .{ 0x011B, 'e' }, .{ 0x011D, 'g' }, .{ 0x011F, 'g' },
    .{ 0x0121, 'g' }, .{ 0x0123, 'g' },  .{ 0x0125, 'h' },  .{ 0x0127, 'h' }, .{ 0x0129, 'i' }, .{ 0x012B, 'i' },
    .{ 0x012D, 'i' }, .{ 0x012F, 'i' },  .{ 0x0130, 'i' },  .{ 0x0131, 'i' }, .{ 0x0135, 'j' }, .{ 0x0137, 'k' },
    .{ 0x013A, 'l' }, .{ 0x013C, 'l' },  .{ 0x013E, 'l' },  .{ 0x0140, 'l' }, .{ 0x0142, 'l' }, .{ 0x0144, 'n' },
    .{ 0x0146, 'n' }, .{ 0x0148, 'n' },  .{ 0x014D, 'o' },  .{ 0x014F, 'o' }, .{ 0x0151, 'o' }, .{ 0x0155, 'r' },
    .{ 0x0157, 'r' }, .{ 0x0159, 'r' },  .{ 0x015B, 's' },  .{ 0x015D, 's' }, .{ 0x015F, 's' }, .{ 0x0161, 's' },
    .{ 0x0163, 't' }, .{ 0x0165, 't' },  .{ 0x0167, 't' },  .{ 0x0169, 'u' }, .{ 0x016B, 'u' }, .{ 0x016D, 'u' },
    .{ 0x016F, 'u' }, .{ 0x0171, 'u' },  .{ 0x0173, 'u' },  .{ 0x0175, 'w' }, .{ 0x0177, 'y' }, .{ 0x0178, 'y' },
    .{ 0x017A, 'z' }, .{ 0x017C, 'z' },  .{ 0x017E, 'z' },  .{ 0x017F, 's' }, .{ 0x0180, 'b' }, .{ 0x0181, 'b' },
    .{ 0x0183, 'b' }, .{ 0x0186, 'o' },  .{ 0x0188, 'c' },  .{ 0x0189, 'd' }, .{ 0x018A, 'd' }, .{ 0x018C, 'd' },
    .{ 0x018E, 'e' }, .{ 0x0190, 'e' },  .{ 0x0192, 'f' },  .{ 0x0193, 'g' }, .{ 0x0197, 'i' }, .{ 0x0199, 'k' },
    .{ 0x019A, 'l' }, .{ 0x019C, 'm' },  .{ 0x019D, 'n' },  .{ 0x019E, 'n' }, .{ 0x019F, 'o' }, .{ 0x01A1, 'o' },
    .{ 0x01A5, 'p' }, .{ 0x01AB, 't' },  .{ 0x01AD, 't' },  .{ 0x01AE, 't' }, .{ 0x01B0, 'u' }, .{ 0x01B2, 'v' },
    .{ 0x01B4, 'y' }, .{ 0x01B6, 'z' },  .{ 0x01CE, 'a' },  .{ 0x01D0, 'i' }, .{ 0x01D2, 'o' }, .{ 0x01D4, 'u' },
    .{ 0x01D6, 'u' }, .{ 0x01D8, 'u' },  .{ 0x01DA, 'u' },  .{ 0x01DC, 'u' }, .{ 0x01DD, 'e' }, .{ 0x01DF, 'a' },
    .{ 0x01E1, 'a' }, .{ 0x01E5, 'g' },  .{ 0x01E7, 'g' },  .{ 0x01E9, 'k' }, .{ 0x01EB, 'o' }, .{ 0x01ED, 'o' },
    .{ 0x01F0, 'j' }, .{ 0x01F5, 'g' },  .{ 0x01F9, 'n' },  .{ 0x01FB, 'a' }, .{ 0x0201, 'a' }, .{ 0x0203, 'a' },
    .{ 0x0205, 'e' }, .{ 0x0207, 'e' },  .{ 0x0209, 'i' },  .{ 0x020B, 'i' }, .{ 0x020D, 'o' }, .{ 0x020F, 'o' },
    .{ 0x0211, 'r' }, .{ 0x0213, 'r' },  .{ 0x0215, 'u' },  .{ 0x0217, 'u' }, .{ 0x0219, 's' }, .{ 0x021B, 't' },
    .{ 0x021F, 'h' }, .{ 0x0220, 'n' },  .{ 0x0221, 'd' },  .{ 0x0225, 'z' }, .{ 0x0227, 'a' }, .{ 0x0229, 'e' },
    .{ 0x022B, 'o' }, .{ 0x022D, 'o' },  .{ 0x022F, 'o' },  .{ 0x0231, 'o' }, .{ 0x0233, 'y' }, .{ 0x0234, 'l' },
    .{ 0x0235, 'n' }, .{ 0x0236, 't' },  .{ 0x0237, 'j' },  .{ 0x023A, 'a' }, .{ 0x023B, 'c' }, .{ 0x023C, 'c' },
    .{ 0x023D, 'l' }, .{ 0x023E, 't' },  .{ 0x023F, 's' },  .{ 0x0240, 'z' }, .{ 0x0243, 'b' }, .{ 0x0244, 'u' },
    .{ 0x0245, 'v' }, .{ 0x0246, 'e' },  .{ 0x0247, 'e' },  .{ 0x0248, 'j' }, .{ 0x0249, 'j' }, .{ 0x024A, 'q' },
    .{ 0x024B, 'q' }, .{ 0x024C, 'r' },  .{ 0x024D, 'r' },  .{ 0x024E, 'y' }, .{ 0x024F, 'y' }, .{ 0x0250, 'a' },
    .{ 0x0251, 'a' }, .{ 0x0253, 'b' },  .{ 0x0254, 'o' },  .{ 0x0255, 'c' }, .{ 0x0256, 'd' }, .{ 0x0257, 'd' },
    .{ 0x0258, 'e' }, .{ 0x025B, 'e' },  .{ 0x025C, 'e' },  .{ 0x025D, 'e' }, .{ 0x025E, 'e' }, .{ 0x025F, 'j' },
    .{ 0x0260, 'g' }, .{ 0x0261, 'g' },  .{ 0x0262, 'g' },  .{ 0x0265, 'h' }, .{ 0x0266, 'h' }, .{ 0x0268, 'i' },
    .{ 0x026A, 'i' }, .{ 0x026B, 'l' },  .{ 0x026C, 'l' },  .{ 0x026D, 'l' }, .{ 0x026F, 'm' }, .{ 0x0270, 'm' },
    .{ 0x0271, 'm' }, .{ 0x0272, 'n' },  .{ 0x0273, 'n' },  .{ 0x0274, 'n' }, .{ 0x0275, 'o' }, .{ 0x0279, 'r' },
    .{ 0x027A, 'r' }, .{ 0x027B, 'r' },  .{ 0x027C, 'r' },  .{ 0x027D, 'r' }, .{ 0x027E, 'r' }, .{ 0x027F, 'r' },
    .{ 0x0280, 'r' }, .{ 0x0281, 'r' },  .{ 0x0282, 's' },  .{ 0x0287, 't' }, .{ 0x0288, 't' }, .{ 0x0289, 'u' },
    .{ 0x028B, 'v' }, .{ 0x028C, 'v' },  .{ 0x028D, 'w' },  .{ 0x028E, 'y' }, .{ 0x028F, 'y' }, .{ 0x0290, 'z' },
    .{ 0x0291, 'z' }, .{ 0x0297, 'c' },  .{ 0x0299, 'b' },  .{ 0x029A, 'e' }, .{ 0x029B, 'g' }, .{ 0x029C, 'h' },
    .{ 0x029D, 'j' }, .{ 0x029E, 'k' },  .{ 0x029F, 'l' },  .{ 0x02A0, 'q' }, .{ 0x02AE, 'h' }, .{ 0x0363, 'a' },
    .{ 0x0364, 'e' }, .{ 0x0365, 'i' },  .{ 0x0366, 'o' },  .{ 0x0367, 'u' }, .{ 0x0368, 'c' }, .{ 0x0369, 'd' },
    .{ 0x036A, 'h' }, .{ 0x036B, 'm' },  .{ 0x036C, 'r' },  .{ 0x036D, 't' }, .{ 0x036E, 'v' }, .{ 0x036F, 'x' },
    .{ 0x1D00, 'a' }, .{ 0x1D03, 'b' },  .{ 0x1D04, 'c' },  .{ 0x1D05, 'd' }, .{ 0x1D07, 'e' }, .{ 0x1D08, 'e' },
    .{ 0x1D09, 'i' }, .{ 0x1D0A, 'j' },  .{ 0x1D0B, 'k' },  .{ 0x1D0C, 'l' }, .{ 0x1D0D, 'm' }, .{ 0x1D0E, 'n' },
    .{ 0x1D0F, 'o' }, .{ 0x1D10, 'o' },  .{ 0x1D11, 'o' },  .{ 0x1D12, 'o' }, .{ 0x1D13, 'o' }, .{ 0x1D16, 'o' },
    .{ 0x1D17, 'o' }, .{ 0x1D18, 'p' },  .{ 0x1D19, 'r' },  .{ 0x1D1A, 'r' }, .{ 0x1D1B, 't' }, .{ 0x1D1C, 'u' },
    .{ 0x1D1D, 'u' }, .{ 0x1D1E, 'u' },  .{ 0x1D1F, 'm' },  .{ 0x1D20, 'v' }, .{ 0x1D21, 'w' }, .{ 0x1D22, 'z' },
    .{ 0x1D62, 'i' }, .{ 0x1D63, 'r' },  .{ 0x1D64, 'u' },  .{ 0x1D65, 'v' }, .{ 0x1E01, 'a' }, .{ 0x1E03, 'b' },
    .{ 0x1E05, 'b' }, .{ 0x1E07, 'b' },  .{ 0x1E09, 'c' },  .{ 0x1E0B, 'd' }, .{ 0x1E0D, 'd' }, .{ 0x1E0F, 'd' },
    .{ 0x1E11, 'd' }, .{ 0x1E13, 'd' },  .{ 0x1E15, 'e' },  .{ 0x1E17, 'e' }, .{ 0x1E19, 'e' }, .{ 0x1E1B, 'e' },
    .{ 0x1E1D, 'e' }, .{ 0x1E1F, 'f' },  .{ 0x1E21, 'g' },  .{ 0x1E23, 'h' }, .{ 0x1E25, 'h' }, .{ 0x1E27, 'h' },
    .{ 0x1E29, 'h' }, .{ 0x1E2B, 'h' },  .{ 0x1E2D, 'i' },  .{ 0x1E2F, 'i' }, .{ 0x1E31, 'k' }, .{ 0x1E33, 'k' },
    .{ 0x1E35, 'k' }, .{ 0x1E37, 'l' },  .{ 0x1E39, 'l' },  .{ 0x1E3B, 'l' }, .{ 0x1E3D, 'l' }, .{ 0x1E3F, 'm' },
    .{ 0x1E41, 'm' }, .{ 0x1E43, 'm' },  .{ 0x1E45, 'n' },  .{ 0x1E47, 'n' }, .{ 0x1E49, 'n' }, .{ 0x1E4B, 'n' },
    .{ 0x1E4D, 'o' }, .{ 0x1E4F, 'o' },  .{ 0x1E51, 'o' },  .{ 0x1E53, 'o' }, .{ 0x1E55, 'p' }, .{ 0x1E57, 'p' },
    .{ 0x1E59, 'r' }, .{ 0x1E5B, 'r' },  .{ 0x1E5D, 'r' },  .{ 0x1E5F, 'r' }, .{ 0x1E61, 's' }, .{ 0x1E63, 's' },
    .{ 0x1E65, 's' }, .{ 0x1E67, 's' },  .{ 0x1E69, 's' },  .{ 0x1E6B, 't' }, .{ 0x1E6D, 't' }, .{ 0x1E6F, 't' },
    .{ 0x1E71, 't' }, .{ 0x1E73, 'u' },  .{ 0x1E75, 'u' },  .{ 0x1E77, 'u' }, .{ 0x1E79, 'u' }, .{ 0x1E7B, 'u' },
    .{ 0x1E7D, 'v' }, .{ 0x1E7F, 'v' },  .{ 0x1E81, 'w' },  .{ 0x1E83, 'w' }, .{ 0x1E85, 'w' }, .{ 0x1E87, 'w' },
    .{ 0x1E89, 'w' }, .{ 0x1E8B, 'x' },  .{ 0x1E8D, 'x' },  .{ 0x1E8F, 'y' }, .{ 0x1E91, 'z' }, .{ 0x1E93, 'z' },
    .{ 0x1E95, 'z' }, .{ 0x1E96, 'h' },  .{ 0x1E97, 't' },  .{ 0x1E98, 'w' }, .{ 0x1E99, 'y' }, .{ 0x1E9A, 'a' },
    .{ 0x1E9B, 's' }, .{ 0x1EA1, 'a' },  .{ 0x1EA3, 'a' },  .{ 0x1EA5, 'a' }, .{ 0x1EA7, 'a' }, .{ 0x1EA9, 'a' },
    .{ 0x1EAB, 'a' }, .{ 0x1EAD, 'a' },  .{ 0x1EAF, 'a' },  .{ 0x1EB1, 'a' }, .{ 0x1EB3, 'a' }, .{ 0x1EB5, 'a' },
    .{ 0x1EB7, 'a' }, .{ 0x1EB9, 'e' },  .{ 0x1EBB, 'e' },  .{ 0x1EBD, 'e' }, .{ 0x1EBF, 'e' }, .{ 0x1EC1, 'e' },
    .{ 0x1EC3, 'e' }, .{ 0x1EC5, 'e' },  .{ 0x1EC7, 'e' },  .{ 0x1EC9, 'i' }, .{ 0x1ECB, 'i' }, .{ 0x1ECD, 'o' },
    .{ 0x1ECF, 'o' }, .{ 0x1ED1, 'o' },  .{ 0x1ED3, 'o' },  .{ 0x1ED5, 'o' }, .{ 0x1ED7, 'o' }, .{ 0x1ED9, 'o' },
    .{ 0x1EDB, 'o' }, .{ 0x1EDD, 'o' },  .{ 0x1EDF, 'o' },  .{ 0x1EE1, 'o' }, .{ 0x1EE3, 'o' }, .{ 0x1EE5, 'u' },
    .{ 0x1EE7, 'u' }, .{ 0x1EE9, 'u' },  .{ 0x1EEB, 'u' },  .{ 0x1EED, 'u' }, .{ 0x1EEF, 'u' }, .{ 0x1EF1, 'u' },
    .{ 0x1EF3, 'y' }, .{ 0x1EF5, 'y' },  .{ 0x1EF7, 'y' },  .{ 0x1EF9, 'y' }, .{ 0x2071, 'i' }, .{ 0x2095, 'h' },
    .{ 0x2096, 'k' }, .{ 0x2097, 'l' },  .{ 0x2098, 'm' },  .{ 0x2099, 'n' }, .{ 0x209A, 'p' }, .{ 0x209B, 's' },
    .{ 0x209C, 't' }, .{ 0x2184, 'c' },  .{ 0xFF01, '!' },  .{ 0xFF02, '"' }, .{ 0xFF03, '#' }, .{ 0xFF04, '$' },
    .{ 0xFF05, '%' }, .{ 0xFF06, '&' },  .{ 0xFF07, '\'' }, .{ 0xFF08, '(' }, .{ 0xFF09, ')' }, .{ 0xFF0A, '*' },
    .{ 0xFF0B, '+' }, .{ 0xFF0C, ',' },  .{ 0xFF0D, '-' },  .{ 0xFF0E, '.' }, .{ 0xFF0F, '/' }, .{ 0xFF10, '0' },
    .{ 0xFF11, '1' }, .{ 0xFF12, '2' },  .{ 0xFF13, '3' },  .{ 0xFF14, '4' }, .{ 0xFF15, '5' }, .{ 0xFF16, '6' },
    .{ 0xFF17, '7' }, .{ 0xFF18, '8' },  .{ 0xFF19, '9' },  .{ 0xFF1A, ':' }, .{ 0xFF1B, ';' }, .{ 0xFF1C, '<' },
    .{ 0xFF1D, '=' }, .{ 0xFF1E, '>' },  .{ 0xFF1F, '?' },  .{ 0xFF20, '@' }, .{ 0xFF21, 'a' }, .{ 0xFF22, 'b' },
    .{ 0xFF23, 'c' }, .{ 0xFF24, 'd' },  .{ 0xFF25, 'e' },  .{ 0xFF26, 'f' }, .{ 0xFF27, 'g' }, .{ 0xFF28, 'h' },
    .{ 0xFF29, 'i' }, .{ 0xFF2A, 'j' },  .{ 0xFF2B, 'k' },  .{ 0xFF2C, 'l' }, .{ 0xFF2D, 'm' }, .{ 0xFF2E, 'n' },
    .{ 0xFF2F, 'o' }, .{ 0xFF30, 'p' },  .{ 0xFF31, 'q' },  .{ 0xFF32, 'r' }, .{ 0xFF33, 's' }, .{ 0xFF34, 't' },
    .{ 0xFF35, 'u' }, .{ 0xFF36, 'v' },  .{ 0xFF37, 'w' },  .{ 0xFF38, 'x' }, .{ 0xFF39, 'y' }, .{ 0xFF3A, 'z' },
    .{ 0xFF3B, '[' }, .{ 0xFF3C, '\\' }, .{ 0xFF3D, ']' },  .{ 0xFF3E, '^' }, .{ 0xFF3F, '_' }, .{ 0xFF40, '`' },
    .{ 0xFF41, 'a' }, .{ 0xFF42, 'b' },  .{ 0xFF43, 'c' },  .{ 0xFF44, 'd' }, .{ 0xFF45, 'e' }, .{ 0xFF46, 'f' },
    .{ 0xFF47, 'g' }, .{ 0xFF48, 'h' },  .{ 0xFF49, 'i' },  .{ 0xFF4A, 'j' }, .{ 0xFF4B, 'k' }, .{ 0xFF4C, 'l' },
    .{ 0xFF4D, 'm' }, .{ 0xFF4E, 'n' },  .{ 0xFF4F, 'o' },  .{ 0xFF50, 'p' }, .{ 0xFF51, 'q' }, .{ 0xFF52, 'r' },
    .{ 0xFF53, 's' }, .{ 0xFF54, 't' },  .{ 0xFF55, 'u' },  .{ 0xFF56, 'v' }, .{ 0xFF57, 'w' }, .{ 0xFF58, 'x' },
    .{ 0xFF59, 'y' }, .{ 0xFF5A, 'z' },  .{ 0xFF5B, '{' },  .{ 0xFF5C, '|' }, .{ 0xFF5D, '}' }, .{ 0xFF5E, '~' },
    .{ 0xFF61, '.' },
};

pub fn lower(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));

    var low: usize = 0;
    var high: usize = ranges.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (ranges[middle].first <= cp) low = middle + 1 else high = middle;
    }
    if (low == 0) return cp;

    const range = ranges[low - 1];
    if (cp > range.last or (cp - range.first) % range.every != 0) return cp;
    return @intCast(@as(i32, cp) + range.delta);
}

pub fn plain(cp: u21) u21 {
    if (cp < 0x80) return cp;

    var low: usize = 0;
    var high: usize = plains.len;
    while (low < high) {
        const middle = low + (high - low) / 2;
        if (plains[middle][0] < cp) low = middle + 1 else high = middle;
    }
    if (low < plains.len and plains[low][0] == cp) return plains[low][1];
    return cp;
}

pub fn accented(term: []const u8) bool {
    var units: Units = .{ .text = term };
    while (units.next()) |unit| {
        if (unit.valid and plain(unit.cp) != unit.cp) return true;
    }
    return false;
}

pub fn fold(gpa: Allocator, text: []const u8) Allocator.Error!Folded {
    if (ascii(text)) {
        const folded = try foldAscii(gpa, text);
        return .{ .text = folded, .plain = folded };
    }

    const sizes = measure(text);

    const cased = try buffers(gpa, sizes.text);
    errdefer release(gpa, cased);

    const bare = if (sizes.plain) |length| try buffers(gpa, length) else cased;

    var cased_at: usize = 0;
    var bare_at: usize = 0;
    var previous: ?Unit = null;
    var units: Units = .{ .text = text };
    while (units.next()) |unit| {
        const start = starting(previous, unit);

        if (start) cased.starts[cased_at >> 3] |= bit(cased_at);
        cased_at += emit(cased.bytes[cased_at..], unit, .text);

        if (sizes.plain != null) {
            if (start) bare.starts[bare_at >> 3] |= bit(bare_at);
            bare_at += emit(bare.bytes[bare_at..], unit, .plain);
        }
        previous = unit;
    }

    return .{
        .text = .{ .bytes = cased.bytes, .starts = cased.starts },
        .plain = .{ .bytes = bare.bytes, .starts = bare.starts },
    };
}

fn foldAscii(gpa: Allocator, text: []const u8) Allocator.Error!Text {
    const made = try buffers(gpa, text.len);

    var before: u8 = ' ';
    for (text, made.bytes, 0..) |byte, *slot, at| {
        slot.* = std.ascii.toLower(byte);
        if (separates[before] or (std.ascii.isLower(before) and std.ascii.isUpper(byte))) {
            made.starts[at >> 3] |= bit(at);
        }
        before = byte;
    }

    return .{ .bytes = made.bytes, .starts = made.starts };
}

fn ascii(text: []const u8) bool {
    for (text) |byte| {
        if (byte >= 0x80) return false;
    }
    return true;
}

const separates = block: {
    var found: [256]bool = @splat(false);
    for (boundary_before) |byte| found[byte] = true;
    break :block found;
};

pub fn query(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const bytes = try gpa.alloc(u8, measure(text).text);

    var written: usize = 0;
    var units: Units = .{ .text = text };
    while (units.next()) |unit| written += emit(bytes[written..], unit, .text);

    return bytes;
}

const Buffers = struct {
    bytes: []u8,
    starts: []u8,
};

fn buffers(gpa: Allocator, length: usize) Allocator.Error!Buffers {
    const bytes = try gpa.alloc(u8, length);
    errdefer gpa.free(bytes);

    const starts = try gpa.alloc(u8, (length + 7) / 8);
    @memset(starts, 0);
    return .{ .bytes = bytes, .starts = starts };
}

fn release(gpa: Allocator, made: Buffers) void {
    gpa.free(made.starts);
    gpa.free(made.bytes);
}

const Form = enum { text, plain };

const Sizes = struct {
    text: usize,
    plain: ?usize,
};

fn measure(text: []const u8) Sizes {
    var cased: usize = 0;
    var bare: usize = 0;
    var differs = false;

    var units: Units = .{ .text = text };
    while (units.next()) |unit| {
        cased += encodedLength(unit, .text);
        bare += encodedLength(unit, .plain);
        if (unit.valid and converted(unit.cp, .plain) != converted(unit.cp, .text)) differs = true;
    }

    return .{ .text = cased, .plain = if (differs) bare else null };
}

fn converted(cp: u21, form: Form) u21 {
    const lowered = lower(cp);
    return switch (form) {
        .text => lowered,
        .plain => plain(lowered),
    };
}

const Unit = struct {
    cp: u21,
    valid: bool,
};

const Units = struct {
    text: []const u8,
    at: usize = 0,

    fn next(self: *Units) ?Unit {
        if (self.at >= self.text.len) return null;

        const lead = self.text[self.at];
        if (lead < 0x80) {
            self.at += 1;
            return .{ .cp = lead, .valid = true };
        }

        const length = std.unicode.utf8ByteSequenceLength(lead) catch return self.raw(lead);
        if (self.at + length > self.text.len) return self.raw(lead);

        const cp = std.unicode.utf8Decode(self.text[self.at..][0..length]) catch return self.raw(lead);
        self.at += length;
        return .{ .cp = cp, .valid = true };
    }

    fn raw(self: *Units, byte: u8) Unit {
        self.at += 1;
        return .{ .cp = byte, .valid = false };
    }
};

fn encodedLength(unit: Unit, form: Form) usize {
    if (!unit.valid) return 1;
    return std.unicode.utf8CodepointSequenceLength(converted(unit.cp, form)) catch unreachable;
}

fn emit(out: []u8, unit: Unit, form: Form) usize {
    if (!unit.valid) {
        out[0] = @intCast(unit.cp);
        return 1;
    }
    return std.unicode.utf8Encode(converted(unit.cp, form), out) catch unreachable;
}

fn starting(previous: ?Unit, unit: Unit) bool {
    const before = previous orelse return true;
    if (!before.valid) return false;
    if (before.cp < 0x80 and separates[before.cp]) return true;
    return unit.valid and lowercase(before.cp) and uppercase(unit.cp);
}

fn uppercase(cp: u21) bool {
    return lower(cp) != cp;
}

fn lowercase(cp: u21) bool {
    if (cp < 0x80) return std.ascii.isLower(@intCast(cp));
    return lettered(cp) and !uppercase(cp);
}

fn lettered(cp: u21) bool {
    if (cp == 0xD7 or cp == 0xF7) return false;
    return switch (cp) {
        0xC0...0x24F, 0x370...0x52F, 0x1E00...0x1FFF => true,
        else => false,
    };
}

fn bit(at: usize) u8 {
    return @as(u8, 1) << @intCast(at & 7);
}

const testing = std.testing;

fn startsOf(arena: Allocator, text: Text) ![]usize {
    var found: std.ArrayList(usize) = .empty;
    for (0..text.bytes.len) |at| {
        if (text.boundary(at)) try found.append(arena, at);
    }
    return found.items;
}

test "upper case folds to lower case across the scripts the table covers" {
    for ([_][2]u21{
        .{ 'A', 'a' },       .{ 'Z', 'z' },     .{ 0xDC, 0xFC },   .{ 0xC9, 0xE9 },
        .{ 0x42F, 0x44F },   .{ 0x401, 0x451 }, .{ 0x3A3, 0x3C3 }, .{ 0x3A9, 0x3C9 },
        .{ 0x1C4, 0x1C6 },   .{ 0x130, 'i' },   .{ 0x1E9E, 0xDF }, .{ 0x23A, 0x2C65 },
        .{ 0x1F08, 0x1F00 }, .{ 0x100, 0x101 }, .{ 0x139, 0x13A }, .{ 0x1EA0, 0x1EA1 },
    }) |pair| try testing.expectEqual(pair[1], lower(pair[0]));
}

test "lower case, digits, signs and code points outside the table are left alone" {
    for ([_]u21{ 'a', '7', ' ', 0xFC, 0xD7, 0xF7, 0x101, 0x44F, 0x2C65, 0x4E2D, 0x1F600 }) |cp| {
        try testing.expectEqual(cp, lower(cp));
    }
}

test "a letter with an accent has a plain form, and the rest keep theirs" {
    for ([_][2]u21{
        .{ 0xE9, 'e' },   .{ 0xFC, 'u' },    .{ 0x142, 'l' },  .{ 0xF8, 'o' },   .{ 0xDF, 's' },
        .{ 0x131, 'i' },  .{ 0x111, 'd' },   .{ 0x1EBF, 'e' }, .{ 0x1EC7, 'e' }, .{ 0x1DC, 'u' },
        .{ 0xFF21, 'a' }, .{ 0xFF07, '\'' },
    }) |pair| try testing.expectEqual(pair[1], plain(pair[0]));

    for ([_]u21{ 'e', 0xE6, 0x2C65, 0x44F, 0x3AC, 0x4E2D }) |cp| try testing.expectEqual(cp, plain(cp));
}

test "a term is accented when its plain form would differ" {
    try testing.expect(!accented("ecole"));
    try testing.expect(accented("école"));
    try testing.expect(accented("straße"));
    try testing.expect(!accented("яндекс"));
    try testing.expect(!accented("\xff"));
}

test "a folded text is lower case and marks where words start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const folded = try fold(arena.allocator(), "Über uns/fooBar");

    try testing.expectEqualStrings("über uns/foobar", folded.text.bytes);
    try testing.expectEqualSlices(usize, &.{ 0, 6, 10, 13 }, try startsOf(arena.allocator(), folded.text));

    try testing.expectEqualStrings("uber uns/foobar", folded.plain.bytes);
    try testing.expectEqualSlices(usize, &.{ 0, 5, 9, 12 }, try startsOf(arena.allocator(), folded.plain));
}

test "accents are left out of the plain form only" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const folded = try fold(arena.allocator(), "École Łódź Straße");
    try testing.expectEqualStrings("école łódź straße", folded.text.bytes);
    try testing.expectEqualStrings("ecole lodz strase", folded.plain.bytes);
}

test "a text that has no accents keeps one copy for both forms" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    for ([_][]const u8{ "Plain ASCII", "Яндекс" }) |text| {
        const folded = try fold(arena.allocator(), text);
        try testing.expectEqual(folded.text.bytes.ptr, folded.plain.bytes.ptr);
        try testing.expectEqual(folded.text.starts.ptr, folded.plain.starts.ptr);
    }
}

test "a fold that changes the length of a character keeps the marks on its start" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const folded = try fold(arena.allocator(), "xİ Ⱥy");

    try testing.expectEqualStrings("xi ⱥy", folded.text.bytes);
    try testing.expectEqualSlices(usize, &.{ 0, 1, 3 }, try startsOf(arena.allocator(), folded.text));
    try testing.expectEqual(folded.text.bytes.ptr, folded.plain.bytes.ptr);
}

test "bytes that are not UTF-8 pass through unchanged" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const folded = try fold(arena.allocator(), "A\xffB\xc3");
    try testing.expectEqualStrings("a\xffb\xc3", folded.text.bytes);
    try testing.expectEqualStrings("a\xffb\xc3", folded.plain.bytes);

    try testing.expectEqualStrings("ü\xfe", try query(arena.allocator(), "Ü\xfe"));
}

test "an ASCII text marks the same starts as the general fold" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const text = "src/main.zig fooBar-baz_qux XMLHttp";
    const quick = try fold(arena.allocator(), text);
    const general = try fold(arena.allocator(), text ++ "\xc3\xbc");

    try testing.expectEqualStrings(quick.text.bytes, general.text.bytes[0..text.len]);
    for (0..text.len) |at| try testing.expectEqual(general.text.boundary(at), quick.text.boundary(at));
}

test "nothing folds to nothing" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();

    const folded = try fold(arena.allocator(), "");
    try testing.expectEqual(0, folded.text.bytes.len);
    try testing.expectEqual(null, folded.plain.find('a', 0));
}
