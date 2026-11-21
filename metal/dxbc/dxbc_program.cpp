#include "dxbc_program.h"

#include <algorithm>
#include <limits>
#include <string_view>

namespace bo3::dxbc {
namespace {

constexpr uint32_t fourcc(std::string_view name) {
    return uint32_t(name[0]) | uint32_t(name[1]) << 8 | uint32_t(name[2]) << 16 |
           uint32_t(name[3]) << 24;
}

uint32_t word(Bytes bytes, size_t at) {
    if (at > bytes.size() || bytes.size() - at < 4)
        throw Error("truncated DXBC field");
    return uint32_t(bytes[at]) | uint32_t(bytes[at + 1]) << 8 |
           uint32_t(bytes[at + 2]) << 16 | uint32_t(bytes[at + 3]) << 24;
}

std::string name_at(Bytes bytes, size_t at) {
    if (at >= bytes.size())
        throw Error("invalid DXBC string offset");
    auto tail = bytes.subspan(at);
    auto end = std::find(tail.begin(), tail.end(), 0);
    if (end == tail.end())
        throw Error("unterminated DXBC string");
    return {tail.begin(), end};
}

void table(Bytes bytes, size_t start, size_t count, size_t stride) {
    if (start > bytes.size() || count > (bytes.size() - start) / stride)
        throw Error("truncated DXBC table");
}

struct Cursor {
    Bytes bytes;
    size_t pos = 0;

    bool done() const { return pos == bytes.size(); }
    uint32_t next() {
        auto value = word(bytes, pos);
        pos += 4;
        return value;
    }

    Operand operand(unsigned depth = 0) {
        if (depth >= 16)
            throw Error("DXBC relative operand nesting exceeds limit");
        Operand out;
        uint32_t token = next();
        out.reg = Reg((token >> 12) & 0xff);
        unsigned shape = token & 3;
        if (shape == 3)
            throw Error("unsupported DXBC variable component count");
        out.components = shape == 2 ? 4 : shape;
        if (shape == 1) {
            out.mask = 1;
            out.swizzle.fill(0);
        } else if (shape == 2) {
            switch ((token >> 2) & 3) {
            case 0:
                out.mask = (token >> 4) & 15;
                break;
            case 1:
                for (unsigned lane = 0; lane < 4; ++lane)
                    out.swizzle[lane] = (token >> (4 + 2 * lane)) & 3;
                break;
            case 2:
                out.swizzle.fill((token >> 4) & 3);
                out.mask = 1 << out.swizzle[0];
                break;
            default:
                throw Error("invalid DXBC component selection");
            }
        }
        uint32_t extension = token;
        while (extension >> 31) {
            extension = next();
            switch (extension & 63) {
            case 0: break;
            case 1:
                out.modifier = (extension >> 6) & 0xff;
                if (out.modifier > 3)
                    throw Error("invalid DXBC operand modifier");
                break;
            default: throw Error("unsupported DXBC operand extension");
            }
        }
        unsigned dimensions = (token >> 20) & 3;
        for (unsigned i = 0; i < dimensions; ++i) {
            Index index;
            switch ((token >> (22 + 3 * i)) & 7) {
            case 0: index.immediate = next(); break;
            case 1:
                index.immediate = uint64_t(next()) << 32;
                index.immediate |= next();
                break;
            case 2: index.relative = std::make_unique<Operand>(operand(depth + 1)); break;
            case 3:
                index.immediate = next();
                index.relative = std::make_unique<Operand>(operand(depth + 1));
                break;
            case 4:
                index.immediate = uint64_t(next()) << 32;
                index.immediate |= next();
                index.relative = std::make_unique<Operand>(operand(depth + 1));
                break;
            default: throw Error("invalid DXBC index representation");
            }
            out.indices.push_back(std::move(index));
        }
        if (out.reg == Reg::Imm32 || out.reg == Reg::Imm64) {
            if (dimensions || (out.components != 1 && out.components != 4))
                throw Error("invalid DXBC immediate operand");
            // A four-lane immediate64 packs two doubles into four DWORDs.
            unsigned words = out.reg == Reg::Imm64 && out.components == 1 ? 2u : out.components;
            for (unsigned i = 0; i < words; ++i)
                out.literal[i] = next();
        }
        return out;
    }
};

bool special_io(Reg reg) {
    switch (reg) {
    case Reg::Primitive: case Reg::Depth: case Reg::DepthGE: case Reg::DepthLE:
    case Reg::Stencil: case Reg::OutputCoverage: case Reg::InputCoverage:
    case Reg::Thread: case Reg::Group: case Reg::LocalThread: case Reg::LocalIndex:
    case Reg::InnerCoverage:
        return true;
    default:
        return false;
    }
}

bool comparison(Op op) {
    return op == Op::SAMPLE_C || op == Op::SAMPLE_C_LZ ||
           op == Op::GATHER4_C || op == Op::GATHER4_PO_C;
}

size_t resource_arg(Op op) {
    if (op >= Op::ATOMIC_AND && op <= Op::ATOMIC_UMIN) return 0;
    if (op >= Op::IMM_ATOMIC_ALLOC && op <= Op::IMM_ATOMIC_UMIN) return 1;
    switch (op) {
    case Op::GATHER4_PO: case Op::GATHER4_PO_C: return 3;
    case Op::SAMPLE: case Op::SAMPLE_C: case Op::SAMPLE_C_LZ: case Op::SAMPLE_L:
    case Op::SAMPLE_D: case Op::SAMPLE_B: case Op::GATHER4: case Op::GATHER4_C:
    case Op::LOD: case Op::LD: case Op::LD_MS: case Op::RESINFO:
    case Op::LD_UAV_TYPED: case Op::LD_RAW: return 2;
    case Op::LD_STRUCTURED: return 3;
    case Op::BUFINFO: case Op::SAMPLE_INFO: case Op::SAMPLE_POS: return 1;
    case Op::STORE_UAV_TYPED: case Op::STORE_RAW: case Op::STORE_STRUCTURED: return 0;
    default: return std::numeric_limits<size_t>::max();
    }
}

bool uses_sampler(Op op) {
    switch (op) {
    case Op::SAMPLE: case Op::SAMPLE_C: case Op::SAMPLE_C_LZ: case Op::SAMPLE_L:
    case Op::SAMPLE_D: case Op::SAMPLE_B: case Op::GATHER4: case Op::GATHER4_C:
    case Op::GATHER4_PO: case Op::GATHER4_PO_C: case Op::LOD: return true;
    default: return false;
    }
}

Dim reflected_dimension(uint32_t value) {
    constexpr Dim dimensions[]{Dim::Unknown, Dim::Buffer, Dim::Tex1D, Dim::Tex1DArray,
        Dim::Tex2D, Dim::Tex2DArray, Dim::Tex2DMS, Dim::Tex2DMSArray, Dim::Tex3D,
        Dim::Cube, Dim::CubeArray, Dim::Raw};
    if (value < std::size(dimensions))
        return dimensions[value];
    return Dim::Unknown;
}

void reflect(Program &p, Bytes bytes) {
    if (bytes.empty())
        return;
    uint32_t cb_count = word(bytes, 0);
    uint32_t cb_offset = word(bytes, 4);
    uint32_t bind_count = word(bytes, 8);
    uint32_t bind_offset = word(bytes, 12);
    unsigned version = word(bytes, 16) & 0xffff;
    size_t bind_stride = version >= 0x501 ? 40 : 32;
    table(bytes, cb_offset, cb_count, 24);
    table(bytes, bind_offset, bind_count, bind_stride);
    std::map<std::string, uint32_t> cb_sizes;
    for (size_t i = 0; i < cb_count; ++i) {
        size_t offset = cb_offset + 24 * i;
        cb_sizes.emplace(name_at(bytes, word(bytes, offset)), word(bytes, offset + 12));
    }
    for (size_t i = 0; i < bind_count; ++i) {
        size_t offset = bind_offset + bind_stride * i;
        auto name = name_at(bytes, word(bytes, offset));
        uint32_t type = word(bytes, offset + 4);
        uint32_t ret = word(bytes, offset + 8);
        auto dim = reflected_dimension(word(bytes, offset + 12));
        uint32_t first = word(bytes, offset + 20);
        uint32_t count = word(bytes, offset + 24);
        if (version >= 0x501 && word(bytes, offset + 32) != 0)
            throw Error("DXBC register spaces require SM5.1 support");
        if (first >= 128 || count > 128 - first)
            throw Error("DXBC reflected binding range exceeds D3D11 limits");
        for (uint32_t slot = first; slot < first + count; ++slot) {
            switch (type) {
            case 0: {
                auto found = cb_sizes.find(name);
                uint64_t size = found == cb_sizes.end() ? 0 : found->second;
                p.cb.try_emplace(slot, (size + 15) / 16);
                break;
            }
            case 1: case 2: p.srv.try_emplace(slot, Resource{type == 1 ? Dim::Buffer : dim, ret}); break;
            case 3: p.samplers.try_emplace(slot); break;
            case 4: p.uav.try_emplace(slot, Resource{dim, ret}); break;
            case 5: p.srv.try_emplace(slot, Resource{Dim::Structured, ret}); break;
            case 6: case 9: case 10: case 11:
                p.uav.try_emplace(slot, Resource{Dim::Structured, ret}).first->second.counter = type >= 9;
                break;
            case 7: p.srv.try_emplace(slot, Resource{Dim::Raw, ret}); break;
            case 8: p.uav.try_emplace(slot, Resource{Dim::Raw, ret}); break;
            default: throw Error("unsupported DXBC reflected resource type " + std::to_string(type));
            }
        }
    }
}

void declare_io(Program &p, Cursor &c, const Instruction &i, bool output, bool sys, bool pixel) {
    Operand arg = c.operand();
    uint32_t system = sys ? c.next() : 0;
    if (special_io(arg.reg)) {
        p.special[arg.reg] = true;
        return;
    }
    if (arg.reg != (output ? Reg::Output : Reg::Input) || arg.slot() >= 32 || system > 255)
        throw Error("invalid DXBC stage I/O declaration");
    auto &d = (output ? p.output : p.input)[arg.slot()];
    d.mask |= arg.mask;
    uint8_t interp = pixel ? uint8_t((i.token >> 11) & 15) : 0;
    for (unsigned j = 0; j < 4; ++j) {
        if (arg.mask & (1u << j)) {
            d.system[j] = uint8_t(system);
            d.interpolation[j] = interp;
        }
    }
}

// Parse declarations separately because their trailing tokens are not operands.
bool declaration(Program &p, Cursor &c, const Instruction &i) {
    switch (i.op) {
    case Op::DCL_GLOBAL_FLAGS:
        p.early_fragment_tests = (i.token & 0x2000) != 0;
        return true;
    case Op::DCL_TEMPS:
        p.temps = c.next();
        if (p.temps > 4096) throw Error("DXBC temporary register limit exceeded");
        return true;
    case Op::DCL_INDEXABLE_TEMP: {
        uint32_t slot = c.next();
        uint32_t count = c.next();
        uint32_t width = c.next();
        if (!count || count > 4096 || slot >= 4096 || !width || width > 4)
            throw Error("invalid DXBC indexable temp declaration");
        p.indexed[slot] = count;
        return true;
    }
    case Op::DCL_INDEX_RANGE: {
        const auto range = c.operand();
        uint32_t count = c.next();
        uint32_t first = range.slot();
        if ((range.reg != Reg::Input && range.reg != Reg::Output) ||
            first >= 32 || !count || count > 32 - first)
            throw Error("invalid DXBC I/O index range");
        return true;
    }
    case Op::DCL_INPUT: declare_io(p, c, i, false, false, false); return true;
    case Op::DCL_INPUT_SIV: case Op::DCL_INPUT_SGV:
        declare_io(p, c, i, false, true, false); return true;
    case Op::DCL_INPUT_PS: declare_io(p, c, i, false, false, true); return true;
    case Op::DCL_INPUT_PS_SIV: case Op::DCL_INPUT_PS_SGV:
        declare_io(p, c, i, false, true, true); return true;
    case Op::DCL_OUTPUT: declare_io(p, c, i, true, false, false); return true;
    case Op::DCL_OUTPUT_SIV: case Op::DCL_OUTPUT_SGV:
        declare_io(p, c, i, true, true, false); return true;
    case Op::DCL_CONSTANT_BUFFER: {
        auto v = c.operand();
        if (v.reg != Reg::Cb) throw Error("invalid DXBC constant buffer declaration");
        auto &size = p.cb[v.slot()];
        uint32_t count = v.slot(1);
        if (count) size = count;
        return true;
    }
    case Op::DCL_SAMPLER: {
        auto v = c.operand();
        if (v.reg != Reg::Sampler) throw Error("invalid DXBC sampler declaration");
        p.samplers.try_emplace(v.slot());
        return true;
    }
    case Op::DCL_RESOURCE: case Op::DCL_UNORDERED_ACCESS_VIEW_TYPED: {
        auto v = c.operand();
        bool uav = i.op == Op::DCL_UNORDERED_ACCESS_VIEW_TYPED;
        if (v.reg != (uav ? Reg::Uav : Reg::Srv))
            throw Error("invalid DXBC typed resource declaration");
        auto &r = (uav ? p.uav : p.srv)[v.slot()];
        r.dim = Dim((i.token >> 11) & 31);
        r.type = c.next() & 15;
        return true;
    }
    case Op::DCL_RESOURCE_RAW: case Op::DCL_UNORDERED_ACCESS_VIEW_RAW:
    case Op::DCL_RESOURCE_STRUCTURED: case Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED:
    case Op::DCL_THREAD_GROUP_SHARED_MEMORY_RAW: case Op::DCL_THREAD_GROUP_SHARED_MEMORY_STRUCTURED: {
        auto v = c.operand();
        bool structured = i.op == Op::DCL_RESOURCE_STRUCTURED ||
                          i.op == Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED ||
                          i.op == Op::DCL_THREAD_GROUP_SHARED_MEMORY_STRUCTURED;
        bool shared = i.op == Op::DCL_THREAD_GROUP_SHARED_MEMORY_RAW ||
                      i.op == Op::DCL_THREAD_GROUP_SHARED_MEMORY_STRUCTURED;
        bool uav = i.op == Op::DCL_UNORDERED_ACCESS_VIEW_RAW ||
                   i.op == Op::DCL_UNORDERED_ACCESS_VIEW_STRUCTURED;
        if (v.reg != (shared ? Reg::Shared : uav ? Reg::Uav : Reg::Srv))
            throw Error("invalid DXBC raw or structured resource declaration");
        auto &r = (shared ? p.shared : uav ? p.uav : p.srv)[v.slot()];
        r.dim = structured ? Dim::Structured : Dim::Raw;
        if (structured) {
            r.stride = c.next();
            if (!r.stride || r.stride % 4)
                throw Error("invalid DXBC structured buffer stride");
        }
        if (shared) {
            r.bytes = uint64_t(c.next()) * (structured ? r.stride : 1);
            if (!r.bytes || r.bytes > 32768 || r.bytes % 4)
                throw Error("invalid DXBC threadgroup memory size");
        }
        if (uav && structured)
            r.counter |= (i.token & (1u << 23)) != 0;
        return true;
    }
    case Op::DCL_THREAD_GROUP:
        for (auto &n : p.threads) {
            n = c.next();
            if (!n || n > 1024)
                throw Error("invalid DXBC threadgroup size");
        }
        if (uint64_t(p.threads[0]) * p.threads[1] * p.threads[2] > 1024)
            throw Error("DXBC threadgroup exceeds 1024 threads");
        return true;
    default: return false;
    }
}

void track_operands(Program &p, const Operand &v) {
    if (special_io(v.reg))
        p.special[v.reg] = true;
    for (const auto &index : v.indices) {
        if (index.relative)
            track_operands(p, *index.relative);
    }
}

void track_instruction(Program &p, const Instruction &i, Dim ext_dim, uint32_t ext_type, uint32_t ext_stride) {
    for (const auto &arg : i.args)
        track_operands(p, arg);
    size_t resource = resource_arg(i.op);
    if (resource >= i.args.size())
        return;
    const auto &arg = i.args[resource];
    if (arg.reg != Reg::Srv && arg.reg != Reg::Uav)
        return;
    auto &r = (arg.reg == Reg::Srv ? p.srv : p.uav)[arg.slot()];
    if (r.dim == Dim::Unknown && ext_dim != Dim::Unknown)
        r.dim = ext_dim;
    if (ext_type)
        r.type = ext_type;
    if (!r.stride)
        r.stride = ext_stride;
    r.comparison |= comparison(i.op);
    r.sampled |= uses_sampler(i.op);
    if (uses_sampler(i.op) && resource + 1 < i.args.size()) {
        const auto &sampler = i.args[resource + 1];
        if (sampler.reg == Reg::Sampler) {
            auto found = p.samplers.find(sampler.slot());
            if (found != p.samplers.end()) {
                if (r.dim == Dim::Cube || r.dim == Dim::CubeArray)
                    found->second.cube = true;
                else
                    found->second.regular = true;
            }
        }
    }
    bool atomic = (i.op >= Op::ATOMIC_AND && i.op <= Op::ATOMIC_UMIN) ||
                  (i.op >= Op::IMM_ATOMIC_IADD && i.op <= Op::IMM_ATOMIC_UMIN);
    r.read |= i.op == Op::LD_UAV_TYPED || atomic;
    r.write |= i.op == Op::STORE_UAV_TYPED || atomic;
    r.counter |= i.op == Op::IMM_ATOMIC_ALLOC || i.op == Op::IMM_ATOMIC_CONSUME;
}

Bo3TexExpect expectation(const Resource &r) {
    switch (r.dim) {
    case Dim::Buffer: case Dim::Structured: case Dim::Raw: return BO3_TEX_BUFFER;
    case Dim::Tex1D: return BO3_TEX_1D;
    case Dim::Tex1DArray: return BO3_TEX_1D_ARRAY;
    case Dim::Tex2D: return r.comparison ? BO3_TEX_DEPTH_2D : BO3_TEX_2D;
    case Dim::Tex2DArray: return r.comparison ? BO3_TEX_DEPTH_2D_ARRAY : BO3_TEX_2D_ARRAY;
    case Dim::Tex2DMS: return BO3_TEX_2D_MS;
    case Dim::Tex2DMSArray: return BO3_TEX_2D_MS_ARRAY;
    case Dim::Cube: return r.comparison ? BO3_TEX_DEPTH_CUBE : BO3_TEX_CUBE;
    case Dim::CubeArray: return r.comparison ? BO3_TEX_DEPTH_CUBE_ARRAY : BO3_TEX_CUBE_ARRAY;
    case Dim::Tex3D: return BO3_TEX_3D;
    default: throw Error("unknown DXBC resource dimension");
    }
}

} // namespace

Container::Container(Bytes data) {
    if (word(data, 0) != fourcc("DXBC"))
        throw Error("invalid DXBC magic");
    uint32_t size = word(data, 24);
    uint32_t count = word(data, 28);
    if (size < 32 || size > data.size() || word(data, 20) != 1)
        throw Error("invalid DXBC container header");
    data = data.first(size);
    table(data, 32, count, 4);
    for (size_t i = 0; i < count; ++i) {
        size_t offset = word(data, 32 + i * 4);
        if (offset < 32 + size_t(count) * 4 || offset % 4)
            throw Error("invalid DXBC chunk offset");
        uint32_t kind = word(data, offset);
        uint32_t length = word(data, offset + 4);
        table(data, offset + 8, length, 1);
        Bytes payload = data.subspan(offset + 8, length);
        switch (kind) {
        case fourcc("ISGN"): case fourcc("ISG1"):
            if (!input_kind || kind == fourcc("ISG1")) {
                input_kind = kind;
                input = payload;
            }
            break;
        case fourcc("OSGN"): case fourcc("OSG1"): case fourcc("OSG5"):
            if (!output_kind || kind == fourcc("OSG1") ||
                (kind == fourcc("OSG5") && output_kind == fourcc("OSGN"))) {
                output_kind = kind;
                output = payload;
            }
            break;
        case fourcc("SHEX"): case fourcc("SHDR"):
            if (code.empty() || kind == fourcc("SHEX")) code = payload;
            break;
        case fourcc("RDEF"): reflection = payload; break;
        default: break;
        }
    }
}

std::vector<DxbcSigElem> signature(Bytes bytes, uint32_t kind) {
    if (!kind)
        return {};
    uint32_t count = word(bytes, 0);
    size_t start = word(bytes, 4);
    bool extended = kind == fourcc("ISG1") || kind == fourcc("OSG1");
    bool stream = extended || kind == fourcc("OSG5");
    size_t stride = extended ? 32 : stream ? 28 : 24;
    if (start < 8)
        throw Error("invalid DXBC signature table offset");
    table(bytes, start, count, stride);
    std::vector<DxbcSigElem> result;
    result.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        size_t at = start + i * stride + (stream ? 4 : 0);
        uint32_t sys = word(bytes, at + 8);
        uint32_t comp = word(bytes, at + 12);
        if (sys > 255 || comp > 3)
            throw Error("invalid DXBC signature component");
        result.push_back({name_at(bytes, word(bytes, at)), word(bytes, at + 4),
                          word(bytes, at + 16), uint8_t(word(bytes, at + 20) & 15),
                          uint8_t(sys), uint8_t(comp)});
    }
    return result;
}

uint32_t Operand::slot(size_t dimension) const {
    if (dimension >= indices.size() || indices[dimension].relative ||
        indices[dimension].immediate > UINT32_MAX)
        throw Error("a static DXBC register index is required");
    return uint32_t(indices[dimension].immediate);
}

void Instruction::count(size_t expected) const {
    if (args.size() != expected)
        throw Error("expected " + std::to_string(expected) + " operands, found " +
                    std::to_string(args.size()));
}

Program::Program(const Container &container) {
    Bytes code = container.code;
    if (code.empty())
        throw Error("DXBC shader bytecode chunk is missing");
    uint32_t version = word(code, 0);
    stage = version >> 16;
    unsigned major = (version >> 4) & 15;
    if ((major != 4 && major != 5) || (version & 15) > (major == 4 ? 1u : 0u))
        throw Error("expected Shader Model 4.0, 4.1, or 5.0 bytecode");
    if (stage == 2)
        throw Error("geometry shaders require a draw expansion pass; Metal has no standalone geometry stage");
    if (stage != 0 && stage != 1 && stage != 5)
        throw Error("unsupported DXBC shader stage " + std::to_string(stage));
    uint32_t length = word(code, 4);
    if (length < 2 || uint64_t(length) * 4 != code.size())
        throw Error("invalid DXBC shader length");
    reflect(*this, container.reflection);
    for (size_t at = 2; at < length;) {
        uint32_t token = word(code, at * 4);
        Op op = Op(token & 2047);
        bool custom = op == Op::CUSTOMDATA;
        uint32_t n = custom ? word(code, (at + 1) * 4) : (token >> 24) & 127;
        if (n < (custom ? 2u : 1u) || n > length - at)
            throw Error("invalid DXBC instruction length at word " + std::to_string(at));
        Cursor c{code.subspan(at * 4, size_t(n) * 4), 4};
        Instruction inst{token, at, op, {}, {}};
        at += n;
        try {
            if (custom) {
                c.next();
                if ((token >> 11) == 3) {
                    if ((n - 2) % 4 || n <= 2 || !icb.empty())
                        throw Error("invalid DXBC immediate constant buffer");
                    while (!c.done()) icb.push_back(c.next());
                }
                continue;
            }
            Dim ext_dim = Dim::Unknown;
            uint32_t ext_type = 0;
            uint32_t ext_stride = 0;
            while (token >> 31) {
                token = c.next();
                switch (token & 63) {
                case 0: break;
                case 1:
                    for (unsigned j = 0; j < 3; ++j) {
                        int value = (token >> (9 + 4 * j)) & 15;
                        inst.offset[j] = value < 8 ? value : value - 16;
                    }
                    break;
                case 2:
                    ext_dim = Dim((token >> 6) & 31);
                    ext_stride = (token >> 11) & 4095;
                    break;
                case 3: ext_type = (token >> 6) & 15; break;
                default: throw Error("unsupported DXBC opcode extension");
                }
            }
            if (declaration(*this, c, inst)) {
                if (!c.done()) throw Error("unexpected data after DXBC declaration");
                continue;
            }
            while (!c.done())
                inst.args.push_back(c.operand());
            track_instruction(*this, inst, ext_dim, ext_type, ext_stride);
            instructions.push_back(std::move(inst));
        } catch (const Error &e) {
            throw Error("DXBC opcode " + std::to_string(unsigned(op)) + " at word " +
                        std::to_string(inst.word) + ": " + e.what());
        }
    }
    uint64_t shared_bytes = 0;
    for (const auto &[slot, r] : shared) shared_bytes += r.bytes;
    if (shared_bytes > 32768)
        throw Error("DXBC threadgroup memory exceeds 32 KiB");
}

void Program::allocate(Bo3BindingMap &m) const {
    std::array<bool, 24> buffers{};
    std::array<bool, 128> textures{};
    auto first_free = [](auto &used, const char *space) {
        auto index = std::find(used.begin(), used.end(), false);
        if (index == used.end()) throw Error(std::string("Metal ") + space + " slots exhausted");
        *index = true;
        return uint8_t(index - used.begin());
    };
    auto buffer = [&]() {
        uint8_t index = first_free(buffers, "buffer");
        m.max_buf_idx = std::max(m.max_buf_idx, index);
        return index;
    };
    for (const auto &[slot, size] : cb) {
        if (slot >= std::size(m.cb) || size > 4096)
            throw Error("DXBC constant buffer declaration exceeds D3D11 limits");
        m.cb[slot] = slot;
        m.cb_mask |= uint16_t(1) << slot;
        buffers[slot] = true;
        m.max_buf_idx = std::max(m.max_buf_idx, uint8_t(slot));
    }
    bool buffer_info = false;
    for (const auto &[slot, r] : srv) {
        if (slot >= std::size(m.srv))
            throw Error("DXBC SRV register exceeds D3D11 limit");
        m.srv_expect[slot] = expectation(r);
        if (r.buffer()) {
            m.srv[slot] = BO3_BIND_IS_BUF | buffer();
            buffer_info = true;
        } else {
            m.srv[slot] = slot;
            textures[slot] = true;
        }
        (slot < 64 ? m.srv_mask_lo : m.srv_mask_hi) |= uint64_t(1) << (slot % 64);
    }
    for (const auto &[slot, r] : uav) {
        if (slot >= std::size(m.uav))
            throw Error("DXBC UAV register exceeds D3D11 limit");
        m.uav_expect[slot] = expectation(r);
        if (r.buffer()) {
            m.uav[slot] = BO3_BIND_IS_BUF | buffer();
            buffer_info = true;
        } else {
            m.uav[slot] = first_free(textures, "texture");
        }
        m.uav_mask |= uint64_t(1) << slot;
    }
    std::array<bool, 16> sampler_slots{};
    for (const auto &[slot, usage] : samplers) {
        if (slot >= std::size(m.smp))
            throw Error("DXBC sampler register exceeds D3D11 limit");
        sampler_slots[slot] = true;
        if (!usage.cube || usage.regular) {
            m.smp[slot] = slot;
            m.smp_mask |= uint16_t(1) << slot;
        }
    }
    for (const auto &[slot, usage] : samplers) {
        if (!usage.cube) continue;
        m.smp_cube[slot] = usage.regular ? first_free(sampler_slots, "sampler") : slot;
        m.smp_cube_mask |= uint16_t(1) << slot;
    }
    if (buffer_info) m.buffer_info_buf = buffer();
    for (const auto &[slot, r] : uav)
        if (r.counter) m.uav_counter_idx[slot] = buffer();
    std::copy(threads.begin(), threads.end(), m.cs_threads);
}

} // namespace bo3::dxbc
