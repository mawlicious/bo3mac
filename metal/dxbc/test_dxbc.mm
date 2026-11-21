// Build from the repository root:
// clang++ -std=c++20 -O1 -g -Wall -Wextra -arch arm64 -fobjc-arc -fsanitize=address,undefined -fno-omit-frame-pointer -framework Foundation -framework Metal metal/dxbc/*.cpp metal/dxbc/test_dxbc.mm -o /tmp/test_dxbc
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <CommonCrypto/CommonDigest.h>

#include "dxbc_format.h"
#include "dxbc_to_msl.h"

#include <algorithm>
#include <array>
#include <bit>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <string_view>
#include <utility>

using bo3::dxbc::Dim;
using bo3::dxbc::Op;
using bo3::dxbc::Reg;
using Words = std::vector<uint32_t>;
using Bytes = std::vector<uint8_t>;

namespace {

void check(bool success, std::string_view reason) {
    if (!success) {
        std::cerr << reason << '\n';
        std::exit(EXIT_FAILURE);
    }
}

uint32_t fourcc(std::string_view name) {
    return uint32_t(name[0]) | uint32_t(name[1]) << 8 | uint32_t(name[2]) << 16 | uint32_t(name[3]) << 24;
}

void append(Bytes &data, uint32_t word) {
    for (unsigned j = 0; j != 4; ++j)
        data.push_back(word >> (8 * j));
}

void patch(Bytes &data, size_t offset, uint32_t word) {
    for (unsigned j = 0; j != 4; ++j)
        data.at(offset + j) = word >> (8 * j);
}

Bytes bytes(const Words &words) {
    Bytes result;
    for (auto word : words) append(result, word);
    return result;
}

struct Code {
    explicit Code(unsigned stage, unsigned version = 0x50) : words{(stage << 16) | version, 0} {}
    Words words;

    void op(Op opcode, std::initializer_list<Words> operands = {}, uint32_t flags = 0) {
        size_t start = words.size();
        words.push_back(uint32_t(opcode) | flags);
        for (const auto &operand : operands)
            words.insert(words.end(), operand.begin(), operand.end());
        words[start] |= uint32_t(words.size() - start) << 24;
    }

    void icb(std::array<uint32_t, 4> data) {
        words.insert(words.end(), {uint32_t(Op::CUSTOMDATA) | (3 << 11), 6});
        words.insert(words.end(), data.begin(), data.end());
    }

    Bytes finish() {
        words[1] = words.size();
        return bytes(words);
    }
};

Words dst(Reg reg, uint32_t slot, unsigned mask = 15) {
    return {2u | mask << 4 | uint32_t(reg) << 12 | 1u << 20, slot};
}

Words src(Reg reg, uint32_t slot, unsigned swizzle = 0xe4) {
    return {6u | swizzle << 4 | uint32_t(reg) << 12 | 1u << 20, slot};
}

Words decl(Reg reg, uint32_t slot) {
    return {uint32_t(reg) << 12 | 1u << 20, slot};
}

Words builtin(Reg reg, unsigned mask) {
    return {2u | mask << 4 | uint32_t(reg) << 12};
}

Words imm(uint32_t value) {
    return {1u | uint32_t(Reg::Imm32) << 12, value};
}

Words immf(float value) {
    return imm(std::bit_cast<uint32_t>(value));
}

Words imm4(uint32_t x, uint32_t y, uint32_t z, uint32_t w) {
    return {2u | uint32_t(Reg::Imm32) << 12, x, y, z, w};
}

Words cb(uint32_t number, uint32_t index) {
    return {6u | 0xe4u << 4 | uint32_t(Reg::Cb) << 12 | 2u << 20, number, index};
}

Bytes signature(unsigned fields, std::initializer_list<DxbcSigElem> elements) {
    Words records{uint32_t(elements.size()), 8};
    Bytes names;
    for (const auto &e : elements) {
        if (fields > 6) records.push_back(0); // stream
        uint32_t offset = 8 + 4 * fields * elements.size() + names.size();
        records.insert(records.end(), {offset, e.semantic_index, e.sys_value_type,
                                       e.component_type, e.register_idx, e.mask});
        if (fields == 8) records.push_back(0); // minimum precision
        names.insert(names.end(), e.semantic_name.begin(), e.semantic_name.end());
        names.push_back(0);
    }
    auto result = bytes(records);
    result.insert(result.end(), names.begin(), names.end());
    return result;
}

void sign_container(Bytes &data) {
    // The DXBC retail digest uses MD5 compression with DXBC-specific final blocks.
    // Hash version onward, excluding the magic and sixteen-byte digest itself.
    const uint32_t size = uint32_t(data.size()) - 20;
    const size_t remainder = size % 64;
    Bytes message(data.begin() + 20, data.end() - remainder);
    if (remainder >= 56) {
        message.insert(message.end(), data.end() - remainder, data.end());
        message.push_back(0x80);
        message.resize(message.size() + 63 - remainder);
    }
    const size_t final = message.size();
    message.resize(final + 64);
    patch(message, final, size << 3);
    if (remainder < 56) {
        std::copy(data.end() - remainder, data.end(), message.begin() + final + 4);
        message[final + 4 + remainder] = 0x80;
    }
    patch(message, final + 60, 1 | size << 1);
    CC_MD5_CTX md5{};
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    check(CC_MD5_Init(&md5) && CC_MD5_Update(&md5, message.data(), uint32_t(message.size())),
          "DXBC digest compression failed");
#pragma clang diagnostic pop
    const std::array digest{md5.A, md5.B, md5.C, md5.D};
    for (size_t i = 0; i < digest.size(); ++i) patch(data, 4 + i * 4, digest[i]);
}

Bytes container(std::initializer_list<std::pair<std::string_view, Bytes>> chunks) {
    auto data = bytes({fourcc("DXBC"), 0, 0, 0, 0, 1, 0, uint32_t(chunks.size())});
    data.resize(32 + 4 * chunks.size());
    size_t index = 0;
    for (const auto &[name, payload] : chunks) {
        // DXBC chunks begin on a DWORD boundary.
        data.resize((data.size() + 3) & ~size_t(3));
        patch(data, 32 + 4 * index++, data.size());
        append(data, fourcc(name));
        append(data, payload.size());
        data.insert(data.end(), payload.begin(), payload.end());
    }
    patch(data, 24, data.size());
    sign_container(data);
    return data;
}

Bytes vertex_shader() {
    Code c(1, 0x40);
    c.op(Op::DCL_INPUT, {dst(Reg::Input, 0)});
    c.op(Op::DCL_INPUT, {dst(Reg::Input, 2)});
    c.op(Op::DCL_INPUT_SGV, {dst(Reg::Input, 3, 1), {6}});
    c.op(Op::DCL_INPUT_SGV, {dst(Reg::Input, 4, 1), {8}});
    c.op(Op::DCL_OUTPUT_SIV, {dst(Reg::Output, 0), {1}});
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 1, 3)});
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 2, 1)});
    c.op(Op::DCL_OUTPUT_SIV, {dst(Reg::Output, 3, 1), {2}});
    c.op(Op::DCL_CONSTANT_BUFFER, {cb(2, 0)});
    // Reflection supplies the constant-buffer size for a declaration with size 0.
    Bytes rdef = bytes({1, 60, 1, 28, 0xfffe0400, 0, 84,
                        84, 0, 0, 0, 0, 2, 1, 0,
                        84, 0, 0, 16, 0, 0});
    rdef.insert(rdef.end(), {'c','o','n','s','t','a','n','t',0});
    c.op(Op::ADD, {dst(Reg::Output, 0), src(Reg::Input, 0), cb(2, 0)});
    c.op(Op::MOV, {dst(Reg::Output, 1, 3), src(Reg::Input, 0)});
    c.op(Op::IADD, {dst(Reg::Output, 2, 1), src(Reg::Input, 2), src(Reg::Input, 3)});
    c.op(Op::IADD, {dst(Reg::Output, 2, 1), src(Reg::Output, 2), src(Reg::Input, 4)});
    c.op(Op::MOV, {dst(Reg::Output, 3, 1), immf(1.0f)});
    c.op(Op::RET);
    return container({
        {"ISG1", signature(8, {{"SV_Position", 0, 0, 15, 0, 3}, {"BLENDINDICES", 0, 2, 15, 0, 1},
                               {"SV_VertexID", 0, 3, 1, 6, 1}, {"SV_InstanceID", 0, 4, 1, 8, 1}})},
        {"OSG1", signature(8, {{"SV_Position", 0, 0, 15, 1, 3}, {"texcoord", 0, 1, 3, 0, 3},
                               {"color", 0, 2, 1, 0, 1}, {"SV_ClipDistance", 0, 3, 1, 2, 3}})},
        {"RDEF", rdef},
        {"SHDR", c.finish()},
    });
}

constexpr uint32_t tex_flags(Dim dim) { return uint32_t(dim) << 11; }

void texture_decl(Code &c, unsigned index, Dim dim, uint32_t type = 0x5555) {
    c.op(Op::DCL_RESOURCE, {decl(Reg::Srv, index), {type}}, tex_flags(dim));
}

Bytes pixel_shader() {
    Code c(0);
    c.op(Op::DCL_TEMPS, {{3}});
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 0, 3)}, 2u << 11);
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 1, 1)}, 1u << 11);
    c.op(Op::DCL_INPUT_PS_SIV, {dst(Reg::Input, 2), {1}}, 4u << 11);
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 0)});
    texture_decl(c, 0, Dim::Tex2D);
    texture_decl(c, 3, Dim::Tex2D);
    c.op(Op::DCL_SAMPLER, {decl(Reg::Sampler, 0)});
    c.op(Op::DCL_SAMPLER, {decl(Reg::Sampler, 1)}, 1u << 11);
    c.op(Op::SAMPLE, {{1 | (1 << 9) | (15 << 13)}, dst(Reg::Temp, 0), src(Reg::Input, 0),
                      src(Reg::Srv, 0), decl(Reg::Sampler, 0)}, 1u << 31);
    c.op(Op::SAMPLE_C_LZ, {dst(Reg::Temp, 1), src(Reg::Input, 0), src(Reg::Srv, 3),
                          decl(Reg::Sampler, 1), immf(0.5f)});
    c.op(Op::MOV, {dst(Reg::Temp, 2), src(Reg::Input, 1, 0)});
    c.op(Op::IF, {src(Reg::Temp, 2, 0)}, 1u << 18);
    c.op(Op::DISCARD, {src(Reg::Temp, 1, 0)});
    c.op(Op::ENDIF);
    c.op(Op::LOOP);
    c.op(Op::MUL, {dst(Reg::Output, 0), src(Reg::Temp, 0), src(Reg::Temp, 1)}, 0x2000);
    c.op(Op::BREAK);
    c.op(Op::ENDLOOP);
    c.op(Op::MOV, {dst(Reg::Output, 0, 8), src(Reg::Input, 2)});
    c.op(Op::RET);
    return container({
        {"ISGN", signature(6, {{"TEXCOORD", 0, 0, 3, 0, 3}, {"COLOR", 0, 1, 1, 0, 1},
                               {"SV_Position", 0, 2, 15, 1, 3}})},
        {"OSGN", signature(6, {{"SV_Target", 0, 0, 15, 0, 3}})},
        {"SHEX", c.finish()},
    });
}

Bytes compute_shader() {
    Code c(5);
    c.op(Op::DCL_GLOBAL_FLAGS, {}, (1u << 12) | (1u << 14));
    c.op(Op::DCL_THREAD_GROUP, {{2, 1, 1}});
    c.op(Op::DCL_TEMPS, {{4}});
    c.op(Op::DCL_INPUT, {builtin(Reg::Thread, 7)});
    c.op(Op::DCL_INPUT, {builtin(Reg::LocalIndex, 1)});
    c.op(Op::DCL_CONSTANT_BUFFER, {cb(0, 1)});
    c.op(Op::DCL_RESOURCE_STRUCTURED, {decl(Reg::Srv, 9), {16}});
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED, {decl(Reg::Uav, 3), {16}});
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_RAW, {decl(Reg::Uav, 0)});
    c.op(Op::DCL_THREAD_GROUP_SHARED_MEMORY_STRUCTURED, {decl(Reg::Shared, 0), {16, 2}});
    c.op(Op::DCL_INDEXABLE_TEMP, {{0, 2, 4}});
    c.icb({1, 2, 3, 4});
    c.op(Op::LD_STRUCTURED, {dst(Reg::Temp, 0), builtin(Reg::Thread, 1), imm(0), src(Reg::Srv, 9)});
    c.op(Op::STORE_STRUCTURED, {dst(Reg::Shared, 0), builtin(Reg::LocalIndex, 1), imm(0), src(Reg::Temp, 0)});
    c.op(Op::SYNC, {}, 0x3800);
    c.op(Op::LD_STRUCTURED, {dst(Reg::Temp, 1), builtin(Reg::LocalIndex, 1), imm(0), src(Reg::Shared, 0)});
    c.op(Op::IMM_ATOMIC_IADD, {dst(Reg::Temp, 2, 1), decl(Reg::Uav, 0), imm(0), imm(1)});
    c.op(Op::IMM_ATOMIC_CMP_EXCH, {dst(Reg::Temp, 3, 1), decl(Reg::Uav, 0), imm(4), imm(0), imm(17)});
    auto indexable_dst = Words{0x002030f2, 0, 1};
    auto indexable_src = Words{0x06203e46, 0, 1, 0x0010000a, 3};
    c.op(Op::MOV, {dst(Reg::Temp, 3, 1), imm(0)});
    c.op(Op::MOV, {indexable_dst, src(Reg::Icb, 0)});
    c.op(Op::IADD, {dst(Reg::Temp, 1), src(Reg::Temp, 1), indexable_src});
    c.op(Op::IADD, {dst(Reg::Temp, 1), src(Reg::Temp, 1), cb(0, 0)});
    c.op(Op::STORE_STRUCTURED, {dst(Reg::Uav, 3), builtin(Reg::Thread, 1), imm(0), src(Reg::Temp, 1)});
    c.op(Op::IF, {builtin(Reg::LocalIndex, 1)});
    c.op(Op::EQ, {dst(Reg::Temp, 2), imm4(0, 0x3f800000, 0x7fc00000, 0x80000000), immf(0.0f)});
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(8), src(Reg::Temp, 2)});
    // Double moves preserve the bit patterns without using Metal double arithmetic.
    c.op(Op::DMOV, {dst(Reg::Temp, 2), {0x00005002, 0, 0x3ff00000, 0, 0x40000000}});
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(24), src(Reg::Temp, 2)});
    c.op(Op::ENDIF);
    c.op(Op::RET);
    return container({{"SHEX", c.finish()}});
}

Bytes texture_shader() {
    Code c(0);
    c.op(Op::DCL_TEMPS, {{9}});
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 0)}, 2u << 11);
    c.op(Op::DCL_INPUT_PS_SGV, {dst(Reg::Input, 1, 1), {9}}, 1u << 11);
    c.op(Op::DCL_INPUT_PS_SGV, {dst(Reg::Input, 2, 1), {10}}, 1u << 11);
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 0)});
    c.op(Op::DCL_OUTPUT, {builtin(Reg::DepthGE, 1)});
    c.op(Op::DCL_OUTPUT, {builtin(Reg::OutputCoverage, 1)});
    texture_decl(c, 2, Dim::Tex2DArray);
    texture_decl(c, 3, Dim::Tex2DArray);
    texture_decl(c, 4, Dim::Cube);
    texture_decl(c, 5, Dim::CubeArray);
    c.op(Op::DCL_RESOURCE, {decl(Reg::Srv, 6), {0x4444}}, tex_flags(Dim::Tex2DMS) | 4u << 16);
    texture_decl(c, 65, Dim::Tex3D);
    c.op(Op::DCL_SAMPLER, {decl(Reg::Sampler, 0)});
    c.op(Op::DCL_SAMPLER, {decl(Reg::Sampler, 1)}, 1u << 11);
    auto v = src(Reg::Input, 0);
    auto r0 = dst(Reg::Temp, 0);
    auto s0 = decl(Reg::Sampler, 0);
    auto s1 = decl(Reg::Sampler, 1);
    auto t2 = src(Reg::Srv, 2);
    auto t3 = src(Reg::Srv, 3);
    auto t4 = src(Reg::Srv, 4);
    auto t5 = src(Reg::Srv, 5);
    auto t6 = src(Reg::Srv, 6);
    c.op(Op::DERIV_RTX_COARSE, {dst(Reg::Temp, 1), v});
    c.op(Op::DERIV_RTY_FINE, {dst(Reg::Temp, 2), v});
    c.op(Op::SAMPLE_D, {r0, v, t2, s0, src(Reg::Temp, 1), src(Reg::Temp, 2)});
    c.op(Op::SAMPLE_B, {r0, v, t2, s0, immf(0.5f)});
    c.op(Op::SAMPLE_L, {r0, v, t4, s0, immf(2.0f)});
    c.op(Op::SAMPLE_C, {r0, v, t3, s1, immf(0.2f)});
    c.op(Op::SAMPLE_C_LZ, {r0, v, t5, s1, immf(0.2f)});
    c.op(Op::LOD, {r0, v, t2, s0});
    c.op(Op::GATHER4, {r0, v, t4, s0});
    c.op(Op::GATHER4_C, {r0, v, t5, s1, immf(0.2f)});
    c.op(Op::GATHER4_PO, {r0, v, imm4(11, uint32_t(-7), 0, 0), t2, s0});
    c.op(Op::GATHER4_PO_C, {r0, v, imm4(11, uint32_t(-7), 0, 0), t3, s1, immf(0.4f)});
    c.op(Op::LD, {r0, imm4(1, 1, 0, 2), t2});
    c.op(Op::LD_MS, {r0, imm4(1, 1, 0, 0), t6, imm(2)});
    c.op(Op::RESINFO, {r0, imm(0), src(Reg::Srv, 65)}, 0x800);
    c.op(Op::SAMPLE_INFO, {r0, t6}, 0x800);
    c.op(Op::SAMPLE_INFO, {r0, builtin(Reg::Rasterizer, 15)});
    c.op(Op::SAMPLE_POS, {r0, builtin(Reg::Rasterizer, 15), imm(0)});
    c.op(Op::MOV, {dst(Reg::Output, 0), src(Reg::Temp, 0)});
    c.op(Op::MOV, {builtin(Reg::DepthGE, 1), immf(0.9f)});
    c.op(Op::MOV, {builtin(Reg::OutputCoverage, 1), src(Reg::Input, 1, 0)});
    c.op(Op::RET);
    return container({{"ISGN", signature(6, {{"TEXCOORD", 0, 0, 15, 0, 3},
                                              {"SV_IsFrontFace", 0, 1, 1, 9, 1},
                                              {"SV_SampleIndex", 0, 2, 1, 10, 1}})},
                      {"SHEX", c.finish()}});
}

Bytes typed_compute_shader() {
    Code c(5);
    c.op(Op::DCL_THREAD_GROUP, {{2, 2, 1}});
    c.op(Op::DCL_TEMPS, {{2}});
    c.op(Op::DCL_INPUT, {builtin(Reg::Thread, 7)});
    c.op(Op::DCL_INPUT, {builtin(Reg::Group, 7)});
    c.op(Op::DCL_INPUT, {builtin(Reg::LocalThread, 7)});
    c.op(Op::DCL_INPUT, {builtin(Reg::LocalIndex, 1)});
    texture_decl(c, 0, Dim::Tex2D);
    c.op(Op::DCL_SAMPLER, {decl(Reg::Sampler, 0)});
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_TYPED, {decl(Reg::Uav, 5), {0x4444}}, tex_flags(Dim::Tex2D));
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED, {decl(Reg::Uav, 3), {4}}, 1u << 23);
    c.op(Op::SAMPLE_L, {dst(Reg::Temp, 0), immf(0.5f), src(Reg::Srv, 0), decl(Reg::Sampler, 0), immf(0)});
    c.op(Op::IMM_ATOMIC_ALLOC, {dst(Reg::Temp, 1, 1), decl(Reg::Uav, 3)});
    c.op(Op::IMM_ATOMIC_CONSUME, {dst(Reg::Temp, 1, 1), decl(Reg::Uav, 3)});
    c.op(Op::BUFINFO, {dst(Reg::Temp, 1), decl(Reg::Uav, 3)});
    auto dst0 = dst(Reg::Temp, 0);
    auto dst1 = dst(Reg::Temp, 1);
    auto arg0 = src(Reg::Temp, 0);
    auto arg1 = imm4(5u, 16u, 0x80000000u, ~0u);
    auto arg2 = imm(3);
    for (Op op : {Op::SQRT, Op::RSQ, Op::RCP, Op::LOG, Op::EXP, Op::FRC, Op::ROUND_NE,
                  Op::ROUND_NI, Op::ROUND_PI, Op::ROUND_Z, Op::F32TOF16, Op::F16TOF32,
                  Op::FTOI, Op::FTOU, Op::ITOF, Op::UTOF, Op::INEG, Op::NOT, Op::BFREV,
                  Op::COUNTBITS, Op::FIRSTBIT_HI, Op::FIRSTBIT_LO, Op::FIRSTBIT_SHI})
        c.op(op, {dst1, arg0});
    for (Op op : {Op::DIV, Op::DP2, Op::DP3, Op::DP4, Op::MIN, Op::MAX, Op::LT, Op::GE, Op::NE,
                  Op::IMIN, Op::IMAX, Op::UMIN, Op::UMAX, Op::IEQ, Op::INE, Op::IGE, Op::ILT,
                  Op::UGE, Op::ULT, Op::ISHL, Op::ISHR, Op::USHR, Op::AND, Op::OR, Op::XOR})
        c.op(op, {dst1, arg0, arg1});
    for (Op op : {Op::MOVC, Op::MAD, Op::IMAD, Op::UMAD, Op::UBFE, Op::IBFE})
        c.op(op, {dst1, arg0, arg1, arg2});
    for (Op op : {Op::IMUL, Op::UMUL, Op::UDIV, Op::UADDC, Op::USUBB})
        c.op(op, {dst0, dst1, arg0, arg1});
    c.op(Op::SINCOS, {dst0, dst1, arg0});
    c.op(Op::BFI, {dst1, arg0, arg1, arg2, arg0});
    c.op(Op::LD_UAV_TYPED, {dst(Reg::Temp, 1), builtin(Reg::Thread, 7), src(Reg::Uav, 5)});
    c.op(Op::STORE_UAV_TYPED, {dst(Reg::Uav, 5), builtin(Reg::Thread, 7), src(Reg::Temp, 1)});
    c.op(Op::RET);
    return container({{"SHEX", c.finish()}});
}

Bytes atomic_texture_shader() {
    Code c(5);
    c.op(Op::DCL_THREAD_GROUP, {{1, 1, 1}});
    c.op(Op::DCL_TEMPS, {{6}});
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_TYPED, {decl(Reg::Uav, 0), {0x4444}}, tex_flags(Dim::Tex2D));
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_TYPED, {decl(Reg::Uav, 1), {0x3333}}, tex_flags(Dim::Tex2DArray));
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED, {decl(Reg::Uav, 3), {4}}, 1u << 23);
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED, {decl(Reg::Uav, 7), {4}});
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_RAW, {decl(Reg::Uav, 8)});
    auto tex = decl(Reg::Uav, 0);
    auto array = decl(Reg::Uav, 1);
    auto xy = imm4(0, 0, 0, 0);
    auto slice = imm4(0, 0, 1, 0);
    c.op(Op::IMM_ATOMIC_IADD, {dst(Reg::Temp, 0, 1), tex, xy, imm(3)});
    c.op(Op::ATOMIC_OR, {tex, xy, imm(8)});
    c.op(Op::ATOMIC_UMIN, {tex, xy, imm(10)});
    c.op(Op::IMM_ATOMIC_CMP_EXCH, {dst(Reg::Temp, 1, 1), tex, xy, imm(10), imm(23)});
    c.op(Op::ATOMIC_CMP_STORE, {tex, xy, imm(10), imm(35)});
    c.op(Op::ATOMIC_XOR, {tex, xy, imm(3)});
    c.op(Op::ATOMIC_AND, {tex, xy, imm(28)});
    c.op(Op::IMM_ATOMIC_EXCH, {dst(Reg::Temp, 2, 1), tex, xy, imm(0x80000002u)});
    c.op(Op::ATOMIC_IMIN, {tex, xy, imm(~0u)});
    c.op(Op::IMM_ATOMIC_UMIN, {dst(Reg::Temp, 3, 1), array, slice, imm(1)});
    c.op(Op::ATOMIC_IMAX, {array, slice, imm(uint32_t(-5))});
    c.op(Op::IMM_ATOMIC_IADD, {dst(Reg::Temp, 4, 1), array, imm4(0, 0, 2, 0), imm(1)});
    c.op(Op::IMM_ATOMIC_ALLOC, {dst(Reg::Temp, 5, 1), decl(Reg::Uav, 3)});
    c.op(Op::IMM_ATOMIC_CONSUME, {dst(Reg::Temp, 5, 2), decl(Reg::Uav, 7)});
    c.op(Op::SYNC, {}, 0x4800);
    for (unsigned i = 0; i < 5; ++i)
        c.op(Op::STORE_RAW, {dst(Reg::Uav, 8, 1), imm(4 * i), src(Reg::Temp, i)});
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 8, 3), imm(20), src(Reg::Temp, 5)});
    c.op(Op::RET);
    return container({{"SHEX", c.finish()}});
}

Bytes integer_varying_vs(uint8_t color_comp_type = 1) {
    Code c(1);
    c.op(Op::DCL_INPUT, {dst(Reg::Input, 0)});
    c.op(Op::DCL_OUTPUT_SIV, {dst(Reg::Output, 0), {1}});
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 1)});
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 2)});
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 3)});
    c.op(Op::MOV, {dst(Reg::Output, 0), src(Reg::Input, 0)});
    c.op(Op::MOV, {dst(Reg::Output, 1), src(Reg::Input, 0)});
    c.op(Op::MOV, {dst(Reg::Output, 2), imm4(7u, 8u, 9u, 10u)});
    c.op(Op::MOV, {dst(Reg::Output, 3), imm4(uint32_t(-1), uint32_t(-2), 3u, 4u)});
    c.op(Op::RET);
    return container({
        {"ISGN", signature(6, {{"POSITION", 0, 0, 15, 0, 3}})},
        {"OSGN", signature(6, {{"SV_Position", 0, 0, 15, 1, 3},
                               {"TEXCOORD", 0, 1, 3, 0, 3},
                               {"TEXCOORD", 2, 1, 4, 0, 3},
                               {"COLOR", 0, 2, 15, 0, color_comp_type},
                               {"TEXCOORD", 1, 3, 15, 0, 2}})},
        {"SHEX", c.finish()},
    });
}

Bytes integer_varying_ps() {
    Code c(0);
    // Test split-register interpolation tracking: v0.xy linear (2), v0.z constant (1).
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 0, 3)}, 2u << 11);
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 0, 4)}, 1u << 11);
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 1)}, 1u << 11);
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 2)}, 1u << 11);
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 0)});
    c.op(Op::IADD, {dst(Reg::Output, 0), src(Reg::Input, 1), src(Reg::Input, 2)});
    c.op(Op::ADD, {dst(Reg::Output, 0), src(Reg::Output, 0), src(Reg::Input, 0)});
    c.op(Op::RET);
    return container({
        {"ISGN", signature(6, {{"TEXCOORD", 0, 0, 3, 0, 3},
                               {"TEXCOORD", 2, 0, 4, 0, 3},
                               {"COLOR", 0, 1, 15, 0, 1},
                               {"TEXCOORD", 1, 2, 15, 0, 2}})},
        {"OSGN", signature(6, {{"SV_Target", 0, 0, 15, 0, 3}})},
        {"SHEX", c.finish()},
    });
}

Bytes cube_only_sampler_ps() {
    Code c(0);
    c.op(Op::DCL_INPUT_PS, {dst(Reg::Input, 0, 7)}, 2u << 11);
    c.op(Op::DCL_OUTPUT, {dst(Reg::Output, 0)});
    texture_decl(c, 0, Dim::Cube);
    c.op(Op::DCL_SAMPLER, {decl(Reg::Sampler, 0)});
    c.op(Op::SAMPLE, {dst(Reg::Output, 0), src(Reg::Input, 0), src(Reg::Srv, 0), decl(Reg::Sampler, 0)});
    c.op(Op::RET);
    // RDEF with 1 sampler binding at slot 0 (previously caused reflect() to set regular=true).
    Bytes rdef = bytes({0, 28, 1, 28, 0xffff0500, 0, 60,
                        60, 3, 0, 0, 0, 0, 1, 0});
    rdef.insert(rdef.end(), {'s', '0', 0});
    return container({
        {"ISGN", signature(6, {{"TEXCOORD", 0, 0, 7, 0, 3}})},
        {"OSGN", signature(6, {{"SV_Target", 0, 0, 15, 0, 3}})},
        {"RDEF", rdef},
        {"SHEX", c.finish()},
    });
}

Bytes resinfo_and_intmod_cs() {
    Code c(5);
    c.op(Op::DCL_THREAD_GROUP, {{1, 1, 1}});
    c.op(Op::DCL_TEMPS, {{6}});
    texture_decl(c, 0, Dim::Tex2DArray);
    c.op(Op::DCL_RESOURCE, {decl(Reg::Srv, 1), {0x5555}}, tex_flags(Dim::Buffer));
    c.op(Op::DCL_UNORDERED_ACCESS_VIEW_RAW, {decl(Reg::Uav, 0)});
    // 0..3: resinfo_rcpFloat on Texture2DArray mip 0 -> (1/8, 1/4, 6, 3)
    c.op(Op::RESINFO, {dst(Reg::Temp, 0), imm(0), src(Reg::Srv, 0)}, 0x0800);
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(0), src(Reg::Temp, 0)});
    // 4..7: resinfo_rcpFloat on Texture2DArray mip 1 -> (1/4, 1/2, 6, 3)
    c.op(Op::RESINFO, {dst(Reg::Temp, 0), imm(1), src(Reg::Srv, 0)}, 0x0800);
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(16), src(Reg::Temp, 0)});
    // 8..11: resinfo_rcpFloat on Texture2DArray OOB mip 5 -> (0, 0, 0, 3)
    c.op(Op::RESINFO, {dst(Reg::Temp, 0), imm(5), src(Reg::Srv, 0)}, 0x0800);
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(32), src(Reg::Temp, 0)});
    // 12..15: resinfo_uint on Dim::Buffer -> (16, 0, 0, 0)
    c.op(Op::RESINFO, {dst(Reg::Temp, 0), imm(0), src(Reg::Srv, 1)}, 0x1000);
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(48), src(Reg::Temp, 0)});
    // 16..19: resinfo_rcpFloat on Dim::Buffer -> (1/16, 0, 0, 0)
    c.op(Op::RESINFO, {dst(Reg::Temp, 0), imm(0), src(Reg::Srv, 1)}, 0x0800);
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(64), src(Reg::Temp, 0)});
    // 20..23: LD in-bounds R32Float texel (0,0,slice=0,mip=0) -> (42.0f, 0, 0, 1.0f)
    c.op(Op::LD, {dst(Reg::Temp, 0), imm4(0, 0, 0, 0), src(Reg::Srv, 0)});
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(80), src(Reg::Temp, 0)});
    // 24..27: LD out-of-bounds texel (99,0,slice=0,mip=0) -> (0, 0, 0, 0)
    c.op(Op::LD, {dst(Reg::Temp, 0), imm4(99, 0, 0, 0), src(Reg::Srv, 0)});
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(96), src(Reg::Temp, 0)});
    // 28..31: IEQ, INE, ISHL with integer negate operand modifier (extended operand bit 31, mod=1:neg)
    c.op(Op::MOV, {dst(Reg::Temp, 1), imm4(5u, uint32_t(-5), 3u, uint32_t(-3))});
    Words neg_r1 = {0x80000000u | 6u | (0xe4u << 4) | (uint32_t(Reg::Temp) << 12) | (1u << 20),
                    1u | (1u << 6), 1u}; // ext type 1 (modifier), modifier = 1 (negate)
    c.op(Op::IEQ, {dst(Reg::Temp, 2, 1), imm(uint32_t(-5)), neg_r1}); // -5 == -(5) -> ~0u
    c.op(Op::INE, {dst(Reg::Temp, 2, 2), imm(uint32_t(-5)), neg_r1}); // -5 != -(5) -> 0u (lane y has -(-5)=5, so -5 != 5 -> ~0u)
    // Shift count with integer negate modifier: -( -3 ) = +3 => 1 << 3 = 8
    Words neg_r1_w = {0x80000000u | 6u | (0xffu << 4) | (uint32_t(Reg::Temp) << 12) | (1u << 20),
                      1u | (1u << 6), 1u};
    c.op(Op::ISHL, {dst(Reg::Temp, 2, 4), imm(1u), neg_r1_w}); // 1 << -(-3) = 8
    c.op(Op::MOV, {dst(Reg::Temp, 2, 8), imm(0x12345678u)});
    c.op(Op::STORE_RAW, {dst(Reg::Uav, 0), imm(112), src(Reg::Temp, 2)});
    c.op(Op::RET);
    return container({{"SHEX", c.finish()}});
}

NSString *ns(const std::string &s) { return [NSString stringWithUTF8String:s.c_str()]; }

DxbcTranslateResult translate(const Bytes &dxbc, const char *name) {
    auto result = bo3_translate_dxbc_to_msl(dxbc.data(), dxbc.size(), name, name);
    check(result.ok, result.error);
    check(result.entry_name == name && !result.msl.empty(), "missing translated entry or source");
    return result;
}

id<MTLFunction> compile(id<MTLDevice> device, const DxbcTranslateResult &shader, MTLLanguageVersion version) {
    NSError *error = nil;
    MTLCompileOptions *options = [MTLCompileOptions new];
    options.languageVersion = version;
    // Avoid deprecated fastMathEnabled when compiling with a recent SDK.
    options.mathMode = MTLMathModeFast;
    id<MTLLibrary> library = [device newLibraryWithSource:ns(shader.msl) options:options error:&error];
    if (!library) std::cerr << shader.msl << '\n';
    check(library != nil, error.localizedDescription.UTF8String ?: "Metal compilation failed");
    id<MTLFunction> function = [library newFunctionWithName:ns(shader.entry_name)];
    check(function != nil, "Metal translated entry not found");
    return function;
}

void graphics_pipeline(id<MTLDevice> device, id<MTLFunction> vs, id<MTLFunction> ps) {
    NSError *error = nil;
    MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
    desc.vertexFunction = vs;
    desc.fragmentFunction = ps;
    desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
    desc.vertexDescriptor = [MTLVertexDescriptor new];
    desc.vertexDescriptor.attributes[0].format = MTLVertexFormatFloat4;
    desc.vertexDescriptor.attributes[0].bufferIndex = 30;
    desc.vertexDescriptor.attributes[2].format = MTLVertexFormatUInt4;
    desc.vertexDescriptor.attributes[2].bufferIndex = 29;
    desc.vertexDescriptor.layouts[30].stride = 16;
    desc.vertexDescriptor.layouts[29].stride = 16;
    check([device newRenderPipelineStateWithDescriptor:desc error:&error] != nil,
          error.localizedDescription.UTF8String ?: "translated VS/PS pipeline linking failed");
}

void dispatch(id<MTLDevice> device, id<MTLFunction> function, const Bo3BindingMap &m) {
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    check(pipeline != nil, error.localizedDescription.UTF8String ?: "compute pipeline creation failed");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    uint32_t inputs[4]{1, 2, 3, 4};
    uint32_t constant[4]{9, 18, 27, 36};
    uint32_t output_zero[8]{};
    uint32_t atomic_zero[10]{};
    auto make_buffer = [&](const void *data, size_t length) {
        return [device newBufferWithBytes:data length:length options:MTLResourceStorageModeShared];
    };
    id<MTLBuffer> srv = make_buffer(inputs, sizeof(inputs));
    id<MTLBuffer> uav = make_buffer(output_zero, sizeof(output_zero));
    id<MTLBuffer> atomics = make_buffer(atomic_zero, sizeof(atomic_zero));
    std::array<uint32_t, 64> info{};
    auto slot = [](unsigned value) { return value & BO3_BIND_IDX_MASK; };
    auto metadata = [&](unsigned binding, uint32_t count, uint32_t stride) {
        info[slot(binding) * 2] = count;
        info[slot(binding) * 2 + 1] = stride;
    };
    metadata(m.srv[9], 1, 16);
    metadata(m.uav[3], 2, 16);
    metadata(m.uav[0], 10, 4);
    [enc setComputePipelineState:pipeline];
    [enc setBytes:constant length:sizeof(constant) atIndex:m.cb[0]];
    [enc setBytes:info.data() length:sizeof(info) atIndex:m.buffer_info_buf];
    [enc setBuffer:srv offset:0 atIndex:slot(m.srv[9])];
    [enc setBuffer:uav offset:0 atIndex:slot(m.uav[3])];
    [enc setBuffer:atomics offset:0 atIndex:slot(m.uav[0])];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:
             MTLSizeMake(m.cs_threads[0], m.cs_threads[1], m.cs_threads[2])];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    check(cmd.status == MTLCommandBufferStatusCompleted,
          cmd.error.localizedDescription.UTF8String ?: "compute dispatch failed");
    uint32_t expected[]{11, 22, 33, 44, 10, 20, 30, 40};
    check(std::memcmp(uav.contents, expected, sizeof(expected)) == 0, "structured buffer or OOB read mismatch");
    uint32_t expected_atomics[]{2, 17, ~0u, 0, 0, ~0u, 0, 0x3ff00000, 0, 0x40000000};
    check(std::memcmp(atomics.contents, expected_atomics, sizeof(expected_atomics)) == 0,
          "atomic, comparison mask or double move mismatch");
}

void dispatch_texture_atomics(id<MTLDevice> device, id<MTLFunction> function, const Bo3BindingMap &m) {
    NSError *error = nil;
    id<MTLComputePipelineState> pipeline = [device newComputePipelineStateWithFunction:function error:&error];
    check(pipeline != nil, error.localizedDescription.UTF8String ?: "texture atomic pipeline creation failed");
    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pipeline];

    MTLTextureDescriptor *desc = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Uint
                                                   width:1 height:1 mipmapped:NO];
    desc.storageMode = MTLStorageModeShared;
    desc.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite | MTLTextureUsageShaderAtomic;
    id<MTLTexture> tex = [device newTextureWithDescriptor:desc];
    desc.textureType = MTLTextureType2DArray;
    desc.arrayLength = 2;
    desc.pixelFormat = MTLPixelFormatR32Sint;
    id<MTLTexture> array = [device newTextureWithDescriptor:desc];
    check(tex && array, "atomic texture allocation failed");
    MTLRegion region = MTLRegionMake2D(0, 0, 1, 1);
    uint32_t texel = 1;
    int32_t signed_texel = -3;
    [tex replaceRegion:region mipmapLevel:0 withBytes:&texel bytesPerRow:4];
    [array replaceRegion:region mipmapLevel:0 slice:0 withBytes:&signed_texel bytesPerRow:4 bytesPerImage:4];
    [array replaceRegion:region mipmapLevel:0 slice:1 withBytes:&signed_texel bytesPerRow:4 bytesPerImage:4];
    [enc setTexture:tex atIndex:m.uav[0]];
    [enc setTexture:array atIndex:m.uav[1]];

    uint32_t initial[] = {4, 9};
    id<MTLBuffer> append = [device newBufferWithBytes:&initial[0] length:4 options:MTLResourceStorageModeShared];
    id<MTLBuffer> consume = [device newBufferWithBytes:&initial[1] length:4 options:MTLResourceStorageModeShared];
    [enc setBuffer:append offset:0 atIndex:m.uav_counter_idx[3]];
    [enc setBuffer:consume offset:0 atIndex:m.uav_counter_idx[7]];
    id<MTLBuffer> output = [device newBufferWithLength:28 options:MTLResourceStorageModeShared];
    unsigned output_slot = m.uav[8] & BO3_BIND_IDX_MASK;
    [enc setBuffer:output offset:0 atIndex:output_slot];
    std::array<uint32_t, 64> info{};
    info[2 * output_slot] = 7;
    info[2 * output_slot + 1] = 4;
    [enc setBytes:info.data() length:sizeof(info) atIndex:m.buffer_info_buf];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    check(cmd.status == MTLCommandBufferStatusCompleted,
          cmd.error.localizedDescription.UTF8String ?: "texture atomic dispatch failed");

    uint32_t expected[]{1, 10, 20, uint32_t(-3), 0, 4, 8};
    check(std::memcmp(output.contents, expected, sizeof(expected)) == 0, "wrong original texture or counter value");
    [tex getBytes:&texel bytesPerRow:4 fromRegion:region mipmapLevel:0];
    check(texel == 0x80000002u, "wrong final unsigned atomic texel");
    [array getBytes:&signed_texel bytesPerRow:4 bytesPerImage:4 fromRegion:region mipmapLevel:0 slice:0];
    check(signed_texel == -3, "texture atomic touched the wrong array slice");
    [array getBytes:&signed_texel bytesPerRow:4 bytesPerImage:4 fromRegion:region mipmapLevel:0 slice:1];
    check(signed_texel == 1, "wrong final signed atomic texel");
    check(*static_cast<uint32_t *>(append.contents) == 5 && *static_cast<uint32_t *>(consume.contents) == 8,
          "independent UAV counters were not updated correctly");
}

void test_aspyr_varying_linking(id<MTLDevice> device) {
    auto vs_bytes = integer_varying_vs(1);
    auto ps_bytes = integer_varying_ps();
    auto vs = translate(vs_bytes, "aspyr_int_vs");
    auto ps = translate(ps_bytes, "aspyr_int_ps");
    check(vs.msl.find("float4 out_1 [[user(TEXCOORD0)]]") != std::string::npos &&
          vs.msl.find("float4 out_2 [[user(TEXCOORD2)]]") != std::string::npos &&
          vs.msl.find("uint4 out_3 [[user(COLOR0)]]") != std::string::npos &&
          vs.msl.find("int4 out_4 [[user(TEXCOORD1)]]") != std::string::npos,
          "VS must emit uint4/int4 user varyings by default");
    check(ps.msl.find("float4 in_0 [[user(TEXCOORD0)]]") != std::string::npos &&
          ps.msl.find("float4 in_1 [[user(TEXCOORD2), flat]]") != std::string::npos &&
          ps.msl.find("uint4 in_2 [[user(COLOR0), flat]]") != std::string::npos &&
          ps.msl.find("int4 in_3 [[user(TEXCOORD1), flat]]") != std::string::npos,
          "PS must emit uint4/int4 flat varyings and preserve per-channel split interpolation");

    // Link translated VS against an Aspyr Generic.metallib-style FS with uint4/int4 inputs.
    NSError *error = nil;
    MTLCompileOptions *opts = [MTLCompileOptions new];
    opts.languageVersion = MTLLanguageVersion3_2;
    NSString *aspyr_msl = @R"msl(
#include <metal_stdlib>
using namespace metal;
struct AspyrPSIn {
    float4 pos [[position]];
    float4 uv [[user(TEXCOORD0)]];
    uint4 col [[user(COLOR0), flat]];
    int4 idx [[user(TEXCOORD1), flat]];
};
fragment float4 aspyr_fs(AspyrPSIn in [[stage_in]]) {
    return in.uv + float4(in.col) + float4(in.idx);
}
struct AspyrVSIn { float4 pos [[attribute(0)]]; };
struct AspyrVSOut {
    float4 pos [[position]];
    float4 uv0 [[user(TEXCOORD0)]];
    float4 uv2 [[user(TEXCOORD2)]];
    uint4 col [[user(COLOR0)]];
    int4 idx [[user(TEXCOORD1)]];
};
vertex AspyrVSOut aspyr_vs(AspyrVSIn in [[stage_in]]) {
    return {in.pos, in.pos, in.pos, uint4(1u), int4(-1)};
}
)msl";
    id<MTLLibrary> aspyr_lib = [device newLibraryWithSource:aspyr_msl options:opts error:&error];
    check(aspyr_lib != nil, error.localizedDescription.UTF8String ?: "Aspyr fixture compile failed");
    auto link_pair = [&](id<MTLFunction> vfn, id<MTLFunction> ffn, const char *label) {
        MTLRenderPipelineDescriptor *d = [MTLRenderPipelineDescriptor new];
        d.vertexFunction = vfn;
        d.fragmentFunction = ffn;
        d.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA8Unorm;
        d.vertexDescriptor = [MTLVertexDescriptor new];
        d.vertexDescriptor.attributes[0].format = MTLVertexFormatFloat4;
        d.vertexDescriptor.attributes[0].bufferIndex = 30;
        d.vertexDescriptor.layouts[30].stride = 16;
        NSError *lerr = nil;
        check([device newRenderPipelineStateWithDescriptor:d error:&lerr] != nil,
              lerr.localizedDescription.UTF8String ?: label);
    };
    link_pair(compile(device, vs, MTLLanguageVersion3_2),
              [aspyr_lib newFunctionWithName:@"aspyr_fs"],
              "translated VS -> Aspyr FS link failed");
    link_pair([aspyr_lib newFunctionWithName:@"aspyr_vs"],
              compile(device, ps, MTLLanguageVersion3_2),
              "Aspyr VS -> translated PS link failed");

    // Verify force_float4_varyings=true bridges mismatched float VS / uint PS pairs.
    auto mismatch_vs_bytes = integer_varying_vs(3); // float COLOR0
    bo3::dxbc::Options f4_opts;
    f4_opts.force_float4_varyings = true;
    auto f4_vs = bo3_translate_dxbc_to_msl(mismatch_vs_bytes.data(), mismatch_vs_bytes.size(),
                                           "f4_vs", "f4_vs", f4_opts);
    auto f4_ps = bo3_translate_dxbc_to_msl(ps_bytes.data(), ps_bytes.size(),
                                           "f4_ps", "f4_ps", f4_opts);
    check(f4_vs.ok && f4_ps.ok, "force_float4_varyings translation failed");
    check(f4_vs.msl.find("float4 out_3 [[user(COLOR0)]]") != std::string::npos &&
          f4_vs.msl.find("float4 out_4 [[user(TEXCOORD1)]]") != std::string::npos &&
          f4_ps.msl.find("float4 in_2 [[user(COLOR0), flat]]") != std::string::npos &&
          f4_ps.msl.find("float4 in_3 [[user(TEXCOORD1), flat]]") != std::string::npos,
          "force_float4_varyings did not emit float4 varyings");
    link_pair(compile(device, f4_vs, MTLLanguageVersion3_2),
              compile(device, f4_ps, MTLLanguageVersion3_2),
              "force_float4_varyings link failed");
}

void dispatch_resinfo_and_intmod(id<MTLDevice> device) {
    auto shader = translate(resinfo_and_intmod_cs(), "test_resinfo_intmod");
    id<MTLFunction> fn = compile(device, shader, MTLLanguageVersion3_2);
    NSError *error = nil;
    id<MTLComputePipelineState> pso = [device newComputePipelineStateWithFunction:fn error:&error];
    check(pso != nil, error.localizedDescription.UTF8String ?: "resinfo compute PSO failed");

    MTLTextureDescriptor *td = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatR32Float
                                                                                  width:8 height:4 mipmapped:YES];
    td.textureType = MTLTextureType2DArray;
    td.arrayLength = 6;
    td.mipmapLevelCount = 3;
    td.storageMode = MTLStorageModeShared;
    td.usage = MTLTextureUsageShaderRead;
    id<MTLTexture> tex = [device newTextureWithDescriptor:td];
    check(tex != nil, "resinfo texture allocation failed");
    float texel = 42.0f;
    [tex replaceRegion:MTLRegionMake2D(0, 0, 1, 1) mipmapLevel:0 slice:0
             withBytes:&texel bytesPerRow:4 bytesPerImage:4];

    id<MTLBuffer> dummy_srv = [device newBufferWithLength:64 options:MTLResourceStorageModeShared];
    id<MTLBuffer> out_buf = [device newBufferWithLength:128 options:MTLResourceStorageModeShared];
    std::memset(out_buf.contents, 0xaa, 128);

    const auto &m = shader.bindings;
    unsigned srv1_slot = m.srv[1] & BO3_BIND_IDX_MASK;
    unsigned uav0_slot = m.uav[0] & BO3_BIND_IDX_MASK;
    std::array<uint32_t, 64> info{};
    info[srv1_slot * 2] = 16;
    info[srv1_slot * 2 + 1] = 4;
    info[uav0_slot * 2] = 32;
    info[uav0_slot * 2 + 1] = 4;

    id<MTLCommandQueue> queue = [device newCommandQueue];
    id<MTLCommandBuffer> cmd = [queue commandBuffer];
    id<MTLComputeCommandEncoder> enc = [cmd computeCommandEncoder];
    [enc setComputePipelineState:pso];
    [enc setTexture:tex atIndex:m.srv[0]];
    [enc setBuffer:dummy_srv offset:0 atIndex:srv1_slot];
    [enc setBuffer:out_buf offset:0 atIndex:uav0_slot];
    [enc setBytes:info.data() length:sizeof(info) atIndex:m.buffer_info_buf];
    [enc dispatchThreadgroups:MTLSizeMake(1, 1, 1) threadsPerThreadgroup:MTLSizeMake(1, 1, 1)];
    [enc endEncoding];
    [cmd commit];
    [cmd waitUntilCompleted];
    check(cmd.status == MTLCommandBufferStatusCompleted,
          cmd.error.localizedDescription.UTF8String ?: "resinfo dispatch failed");

    const auto *f = static_cast<const float *>(out_buf.contents);
    const auto *u = static_cast<const uint32_t *>(out_buf.contents);
    // resinfo_rcpFloat mip 0: (1/8, 1/4, 6, 3) — array_size=6 and num_mips=3 NOT inverted!
    check(f[0] == 0.125f && f[1] == 0.25f && f[2] == 6.0f && f[3] == 3.0f,
          "resinfo_rcpFloat Texture2DArray mip 0 mismatch");
    // resinfo_rcpFloat mip 1: (1/4, 1/2, 6, 3)
    check(f[4] == 0.25f && f[5] == 0.5f && f[6] == 6.0f && f[7] == 3.0f,
          "resinfo_rcpFloat Texture2DArray mip 1 mismatch");
    // resinfo_rcpFloat OOB mip 5: (0, 0, 0, 3)
    check(f[8] == 0.0f && f[9] == 0.0f && f[10] == 0.0f && f[11] == 3.0f,
          "resinfo_rcpFloat Texture2DArray OOB mip mismatch");
    // resinfo_uint Dim::Buffer: (16, 0, 0, 0)
    check(u[12] == 16u && u[13] == 0u && u[14] == 0u && u[15] == 0u,
          "resinfo_uint Dim::Buffer mismatch");
    // resinfo_rcpFloat Dim::Buffer: (1/16, 0, 0, 0)
    check(f[16] == 0.0625f && f[17] == 0.0f && f[18] == 0.0f && f[19] == 0.0f,
          "resinfo_rcpFloat Dim::Buffer mismatch");
    // LD in-bounds R32Float: (42.0f, 0, 0, 1.0f) — default alpha preserved
    check(f[20] == 42.0f && f[21] == 0.0f && f[22] == 0.0f && f[23] == 1.0f,
          "LD in-bounds R32Float default alpha mismatch");
    // LD out-of-bounds: (0, 0, 0, 0) — all zeros
    check(f[24] == 0.0f && f[25] == 0.0f && f[26] == 0.0f && f[27] == 0.0f,
          "LD out-of-bounds zero mismatch");
    // IEQ/INE/ISHL integer negate modifier
    check(u[28] == ~0u && u[29] == ~0u && u[30] == 8u && u[31] == 0x12345678u,
          "IEQ/INE/ISHL integer modifier mismatch");
}

} // namespace

int main() {
    @autoreleasepool {
        id<MTLDevice> device = MTLCreateSystemDefaultDevice();
        check(device != nil, "Metal device unavailable");
        auto vs_bytes = vertex_shader();
        auto ps_bytes = pixel_shader();
        auto cs_bytes = compute_shader();
        auto vs = translate(vs_bytes, "test_vs");
        auto ps = translate(ps_bytes, "test_ps");
        check(vs.msl.find("float4 out_1 [[user(TEXCOORD0)]]") != std::string::npos &&
              ps.msl.find("float4 in_0 [[user(TEXCOORD0)]]") != std::string::npos &&
              vs.msl.find("uint4 out_2 [[user(COLOR0)]]") != std::string::npos &&
              ps.msl.find("uint4 in_1 [[user(COLOR0), flat]]") != std::string::npos,
              "stage varyings must use Aspyr-compatible four-lane types and names");
        check(vs.msl.find("[[base_vertex]]") != std::string::npos &&
              vs.msl.find("[[base_instance]]") != std::string::npos &&
              vs.msl.find("in_2 - dx_base_vertex") != std::string::npos &&
              vs.msl.find("in_3 - dx_base_instance") != std::string::npos &&
              ps.msl.find("as_type<uint>(1.0f / dx_stage.in_2.w)") != std::string::npos,
              "system input conversions missing");
        auto cs = translate(cs_bytes, "test_cs");
        check(vs.stage == 1 && vs.bindings.cb_mask == 4 && vs.bindings.cb[2] == 2 &&
              vs.bindings.max_buf_idx == 2 && vs.bindings.vs_input_mask == 5 &&
              vs.bindings.vs_input_types[0] == 0 && vs.bindings.vs_input_types[2] == 1,
              "incorrect vertex binding map");
        check(ps.stage == 0 && ps.bindings.srv_mask_lo == 9 && ps.bindings.srv[0] == 0 &&
              ps.bindings.srv[3] == 3 && ps.bindings.srv_expect[3] == BO3_TEX_DEPTH_2D &&
              ps.bindings.smp_mask == 3 && ps.bindings.smp[1] == 1 &&
              ps.bindings.smp_cube[1] == BO3_BIND_UNUSED,
              "incorrect fragment binding map");
        check(cs.stage == 5 && cs.bindings.cb[0] == 0 &&
              cs.bindings.srv[9] == (BO3_BIND_IS_BUF | 1) &&
              cs.bindings.uav[0] == (BO3_BIND_IS_BUF | 2) &&
              cs.bindings.uav[3] == (BO3_BIND_IS_BUF | 3) && cs.bindings.icb_buf == BO3_BIND_UNUSED &&
              cs.msl.find("*icb [[buffer(") == std::string::npos &&
              cs.bindings.buffer_info_buf == 4 && cs.bindings.max_buf_idx == 4 && cs.bindings.cs_threads[0] == 2 &&
              cs.bindings.cs_threads[1] == 1 && cs.bindings.cs_threads[2] == 1,
              "incorrect compute binding map");
        auto textures = translate(texture_shader(), "test_textures");
        auto typed = translate(typed_compute_shader(), "test_typed_compute");
        check(textures.bindings.srv_mask_hi == 2 && textures.bindings.srv_expect[3] == BO3_TEX_DEPTH_2D_ARRAY &&
              textures.bindings.srv_expect[5] == BO3_TEX_DEPTH_CUBE_ARRAY, "incorrect texture metadata");
        check(textures.bindings.smp_cube_mask == 3 && textures.bindings.smp_cube[0] == 2 &&
              textures.bindings.smp_cube[1] == 3 && textures.msl.find("t4.sample(s0cube, ") != std::string::npos,
              "incorrect cube sampler bindings");
        check(typed.bindings.uav[5] == 1 && typed.bindings.uav_counter_idx[3] == 2 &&
              typed.bindings.uav_counters_buf == BO3_BIND_UNUSED && typed.bindings.max_buf_idx == 2,
              "incorrect typed UAV or counter bindings");
        auto atomic = translate(atomic_texture_shader(), "test_texture_atomics");
        check(atomic.bindings.uav_counter_idx[3] == 4 && atomic.bindings.uav_counter_idx[7] == 5 &&
              atomic.bindings.uav_counters_buf == BO3_BIND_UNUSED && atomic.bindings.max_buf_idx == 5 &&
              atomic.msl.find("u3_counter [[buffer(4)]]") != std::string::npos &&
              atomic.msl.find("u7_counter [[buffer(5)]]") != std::string::npos,
              "incorrect dedicated counter bindings");
        {
            auto fence_pos = atomic.msl.find(
                "atomic_thread_fence(mem_flags::mem_device | mem_flags::mem_texture, memory_order_seq_cst);");
            auto barrier_pos = atomic.msl.find(
                "threadgroup_barrier(mem_flags::mem_device | mem_flags::mem_texture);");
            check(fence_pos != std::string::npos && barrier_pos != std::string::npos && fence_pos < barrier_pos,
                  "sync_uglobal_t must emit device-scope atomic_thread_fence before threadgroup_barrier");
        }
        auto cube_only = translate(cube_only_sampler_ps(), "test_cube_only_sampler");
        check(cube_only.bindings.smp[0] == BO3_BIND_UNUSED && cube_only.bindings.smp_mask == 0 &&
              cube_only.bindings.smp_cube[0] == 0 && cube_only.bindings.smp_cube_mask == 1 &&
              cube_only.msl.find("sampler s0 ") == std::string::npos &&
              cube_only.msl.find("sampler s0cube [[sampler(0)]]") != std::string::npos,
              "cube-only sampler with RDEF must allocate only s0cube (1 sampler slot)");
        compile(device, cube_only, MTLLanguageVersion3_2);
        std::vector<DxbcSigElem> input;
        check(bo3_parse_dxbc_input_signature(vs_bytes.data(), vs_bytes.size(), &input) &&
              input.size() == 4 && input[1].semantic_name == "BLENDINDICES" &&
              input[1].component_type == 1 && input[1].register_idx == 2, "ISG1 reflection mismatch");
        check(bo3_parse_dxbc_input_signature(ps_bytes.data(), ps_bytes.size(), &input) &&
              input.size() == 3 && input[0].mask == 3, "ISGN reflection mismatch");
        for (size_t len = 0; len < vs_bytes.size(); ++len)
            check(!bo3_parse_dxbc_input_signature(vs_bytes.data(), len, &input), "truncated DXBC accepted");
        auto bad = bo3_translate_dxbc_to_msl(nullptr, 0, nullptr, "bad_shader");
        check(!bad.ok && bad.error.starts_with("bad_shader:") && bad.bindings.cb[0] == BO3_BIND_UNUSED,
              "invalid DXBC diagnostics or binding initialization");
        for (auto version : {MTLLanguageVersion2_4, MTLLanguageVersion3_0, MTLLanguageVersion3_2}) {
            auto vertex = compile(device, vs, version);
            auto fragment = compile(device, ps, version);
            auto kernel = compile(device, cs, version);
            compile(device, textures, version);
            compile(device, typed, version);
            graphics_pipeline(device, vertex, fragment);
            dispatch(device, kernel, cs.bindings);
            std::cout << "MSL " << (version == MTLLanguageVersion2_4 ? "2.4" : version == MTLLanguageVersion3_0 ? "3.0" : "3.2")
                      << " five fixtures compiled, render pipeline linked, compute dispatch matched\n";
        }
        dispatch_texture_atomics(device, compile(device, atomic, MTLLanguageVersion3_2), atomic.bindings);
        test_aspyr_varying_linking(device);
        dispatch_resinfo_and_intmod(device);
        std::cout << "MSL 3.2 texture atomics, sync_uglobal_t, Aspyr varying linking, resinfo_rcpFloat, LD OOB and int modifiers passed GPU verification\n";
        std::cout << "PASS on " << device.name.UTF8String << '\n';
    }
}
