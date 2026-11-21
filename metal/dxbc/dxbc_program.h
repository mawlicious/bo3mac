#pragma once
#include "dxbc_format.h"
#include "dxbc_to_msl.h"

#include <array>
#include <map>
#include <memory>
#include <span>
#include <stdexcept>

namespace bo3::dxbc {

using Bytes = std::span<const uint8_t>;

struct Error : std::runtime_error {
    using std::runtime_error::runtime_error;
};

struct Container {
    explicit Container(Bytes data);
    Bytes input;
    Bytes output;
    Bytes code;
    Bytes reflection;
    uint32_t input_kind = 0;
    uint32_t output_kind = 0;
};

std::vector<DxbcSigElem> signature(Bytes bytes, uint32_t kind);

struct Operand;

struct Index {
    uint64_t immediate = 0;
    std::unique_ptr<Operand> relative;
};

struct Operand {
    Reg reg{};
    uint8_t components = 0;
    uint8_t mask = 0xf;
    std::array<uint8_t, 4> swizzle{0, 1, 2, 3};
    uint8_t modifier = 0;
    std::vector<Index> indices;
    std::array<uint32_t, 4> literal{};

    uint32_t slot(size_t dimension = 0) const;
};

struct Instruction {
    uint32_t token{};
    size_t word{};
    Op op{};
    std::array<int, 3> offset{};
    std::vector<Operand> args;

    void count(size_t expected) const;
};

struct Resource {
    Dim dim = Dim::Unknown;
    uint32_t type = 5; // D3D_RESOURCE_RETURN_TYPE_FLOAT
    uint32_t stride = 0;
    uint64_t bytes = 0;
    bool comparison = false;
    bool counter = false;
    bool read = false;
    bool write = false;
    bool sampled = false;

    bool buffer() const { return dim == Dim::Buffer || dim == Dim::Raw || dim == Dim::Structured; }
};

struct Declaration {
    uint8_t mask = 0;
    std::array<uint8_t, 4> system{};
    std::array<uint8_t, 4> interpolation{};

    uint8_t system_for(uint8_t lanes) const {
        for (unsigned j = 0; j < 4; ++j)
            if ((lanes & (1u << j)) && system[j]) return system[j];
        return 0;
    }

    uint8_t interpolation_for(uint8_t lanes) const {
        for (unsigned j = 0; j < 4; ++j)
            if ((lanes & (1u << j)) && interpolation[j]) return interpolation[j];
        return 0;
    }
};

struct SamplerUsage {
    bool regular = false;
    bool cube = false;
};

struct Program {
    uint16_t stage = 0;
    uint32_t temps = 0;
    bool early_fragment_tests = false;
    std::array<uint32_t, 3> threads{1, 1, 1};
    std::map<uint32_t, uint32_t> indexed;
    std::map<uint32_t, uint32_t> cb;
    std::map<uint32_t, Resource> srv;
    std::map<uint32_t, Resource> uav;
    std::map<uint32_t, Resource> shared;
    std::map<uint32_t, SamplerUsage> samplers;
    std::map<uint32_t, Declaration> input;
    std::map<uint32_t, Declaration> output;
    std::map<Reg, bool> special;
    std::vector<uint32_t> icb;
    std::vector<Instruction> instructions;

    explicit Program(const Container &container);
    void allocate(Bo3BindingMap &map) const;
};

} // namespace bo3::dxbc
