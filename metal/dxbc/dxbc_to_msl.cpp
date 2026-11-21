#include "dxbc_program.h"

#include <algorithm>
#include <initializer_list>
#include <string_view>

namespace bo3::dxbc {
namespace {

using Str = std::string;
using View = std::string_view;

constexpr View xyzw = "xyzw";

Str decimal(uint64_t n) { return std::to_string(n); }
Str unsigned_literal(uint64_t n) { return decimal(n) + "u"; }
Str member(View value, View lanes) { return "(" + Str(value) + ")." + Str(lanes); }

Str call(View function, std::initializer_list<View> args) {
    Str result(function);
    result += '(';
    bool first = true;
    for (View arg : args) {
        if (!first) result += ", ";
        first = false;
        result += arg;
    }
    return result + ')';
}

Str cast(View type, View value) { return call(type, {value}); }
Str bits(View type, View value) { return cast("as_type<" + Str(type) + ">", value); }
Str paren(View expression) { return "(" + Str(expression) + ")"; }

Str register_name(View prefix, uint32_t slot) {
    return Str(prefix) + decimal(slot);
}

Str uppercase(View name) {
    Str upper(name);
    for (char &c : upper)
        if (c >= 'a' && c <= 'z') c -= 'a' - 'A';
    return upper;
}

bool identifier(View name) {
    auto letter = [](char c) { return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z') || c == '_'; };
    return !name.empty() && letter(name.front()) &&
           std::all_of(name.begin() + 1, name.end(),
                       [&](char c) { return letter(c) || (c >= '0' && c <= '9'); });
}

View system_name(unsigned sys) {
    switch (sys) {
    case 1: return "SV_POSITION";
    case 2: return "SV_CLIPDISTANCE";
    case 3: return "SV_CULLDISTANCE";
    case 4: return "SV_RENDERTARGETARRAYINDEX";
    case 5: return "SV_VIEWPORTARRAYINDEX";
    case 6: return "SV_VERTEXID";
    case 7: return "SV_PRIMITIVEID";
    case 8: return "SV_INSTANCEID";
    case 9: return "SV_ISFRONTFACE";
    case 10: return "SV_SAMPLEINDEX";
    case 64: return "SV_TARGET";
    case 65: return "SV_DEPTH";
    case 66: return "SV_COVERAGE";
    case 67: return "SV_DEPTHGREATEREQUAL";
    case 68: return "SV_DEPTHLESSEQUAL";
    case 69: return "SV_STENCILREF";
    default: return {};
    }
}

Str scalar_type(unsigned type) {
    if (type == 1) return "uint";
    if (type == 2) return "int";
    return "float";
}

struct IoField {
    Str name;
    Str attribute;
    Str type;
    Str reg;
    uint8_t mask = 0;
    bool builtin_argument = false;
    bool scalar = false;
    bool front = false;
    bool register_aligned = false;
    int clip_base = -1;
};

struct SpecialIo {
    Reg reg;
    View semantic;
    View name;
    View attribute;
    View type;
    bool output = false;
};

constexpr SpecialIo special_fields[]{
    {Reg::Primitive, "SV_PRIMITIVEID", "primitive", "primitive_id", "uint"},
    {Reg::Depth, "SV_DEPTH", "depth", "depth(any)", "float", true},
    {Reg::DepthGE, "SV_DEPTHGREATEREQUAL", "depth_ge", "depth(greater)", "float", true},
    {Reg::DepthLE, "SV_DEPTHLESSEQUAL", "depth_le", "depth(less)", "float", true},
    {Reg::Stencil, "SV_STENCILREF", "stencil", "stencil", "uint", true},
    {Reg::OutputCoverage, "SV_COVERAGE", "out_coverage", "sample_mask", "uint", true},
    {Reg::InputCoverage, "SV_COVERAGE", "in_coverage", "sample_mask", "uint"},
    {Reg::Thread, "SV_DISPATCHTHREADID", "thread_id", "thread_position_in_grid", "uint3"},
    {Reg::Group, "SV_GROUPID", "group_id", "threadgroup_position_in_grid", "uint3"},
    {Reg::LocalThread, "SV_GROUPTHREADID", "local_thread", "thread_position_in_threadgroup", "uint3"},
    {Reg::LocalIndex, "SV_GROUPINDEX", "local_index", "thread_index_in_threadgroup", "uint"},
};

Str special_register(Reg reg) {
    for (const auto &field : special_fields)
        if (field.reg == reg) return "dx_" + Str(field.name);
    throw Error("unsupported DXBC register type " + decimal(unsigned(reg)));
}

Str lanes_for_mask(uint8_t mask) {
    Str lanes;
    for (unsigned j = 0; j < 4; ++j)
        if (mask & (1 << j)) lanes += xyzw[j];
    return lanes;
}

Str swizzle(const Operand &arg, View value) {
    Str lanes;
    for (auto lane : arg.swizzle) lanes += xyzw[lane];
    return lanes == xyzw ? Str(value) : member(value, lanes);
}

Str interpolation(unsigned mode, bool integer) {
    if (mode == 1 || integer) return ", flat";
    switch (mode) {
    case 3: return ", centroid_perspective";
    case 4: return ", center_no_perspective";
    case 5: return ", centroid_no_perspective";
    case 6: return ", sample_perspective";
    case 7: return ", sample_no_perspective";
    default: return {};
    }
}

Str texture_type(const Resource &r, bool uav) {
    View base;
    switch (r.dim) {
    case Dim::Tex1D: base = "texture1d"; break;
    case Dim::Tex1DArray: base = "texture1d_array"; break;
    case Dim::Tex2D: base = r.comparison ? "depth2d" : "texture2d"; break;
    case Dim::Tex2DArray: base = r.comparison ? "depth2d_array" : "texture2d_array"; break;
    case Dim::Tex2DMS: base = "texture2d_ms"; break;
    case Dim::Tex2DMSArray: base = "texture2d_ms_array"; break;
    case Dim::Tex3D: base = "texture3d"; break;
    case Dim::Cube: base = r.comparison ? "depthcube" : "texturecube"; break;
    case Dim::CubeArray: base = r.comparison ? "depthcube_array" : "texturecube_array"; break;
    default: throw Error("invalid DXBC texture dimension");
    }
    if (r.comparison && !base.starts_with("depth"))
        throw Error("DXBC comparison requires a 2D or cube depth texture");
    Str type = r.type == 3 ? "int" : r.type == 4 ? "uint" : "float";
    View access = "sample";
    if (uav) {
        access = r.read && r.write ? "read_write" : r.write ? "write" : "read";
    } else if (r.dim == Dim::Tex2DMS || r.dim == Dim::Tex2DMSArray ||
               (!r.sampled && !r.comparison)) {
        access = "read";
    }
    return Str(base) + "<" + type + ", access::" + Str(access) + ">";
}

struct TextureShape {
    unsigned axes;
    bool array;
    bool ms;
    bool cube;
};

TextureShape shape(Dim dim) {
    switch (dim) {
    case Dim::Tex1D: return {1, false, false, false};
    case Dim::Tex1DArray: return {1, true, false, false};
    case Dim::Tex2D: return {2, false, false, false};
    case Dim::Tex2DArray: return {2, true, false, false};
    case Dim::Tex2DMS: return {2, false, true, false};
    case Dim::Tex2DMSArray: return {2, true, true, false};
    case Dim::Tex3D: return {3, false, false, false};
    case Dim::Cube: return {3, false, false, true};
    case Dim::CubeArray: return {3, true, false, true};
    default: throw Error("DXBC operand is not a texture");
    }
}

Str vector_type(View scalar, unsigned width) {
    return Str(scalar) + (width == 1 ? "" : decimal(width));
}

Str texel_bounds(View tex, View coord, const TextureShape &shape) {
    constexpr View queries[] = {"get_width", "get_height", "get_depth"};
    Str check;
    for (unsigned j = 0; j < shape.axes; ++j) {
        if (j) check += " && ";
        check += Str(coord) + "." + xyzw[j] + " < " + Str(tex) + "." + Str(queries[j]) + "()";
    }
    if (shape.array)
        check += " && " + Str(coord) + "." + xyzw[shape.axes] + " < " + Str(tex) + ".get_array_size()";
    return check;
}

struct Writer {
    Str source;
    unsigned indent = 0;

    void line(View value) {
        source.append(indent * 4, ' ');
        source += value;
        source += '\n';
    }

    void open(View value) {
        line(Str(value) + " {");
        ++indent;
    }

    void close(View suffix = {}) {
        --indent;
        line("}" + Str(suffix));
    }
};

const Resource &resource_at(const std::map<uint32_t, Resource> &resources, uint32_t slot) {
    auto found = resources.find(slot);
    if (found == resources.end())
        throw Error("undeclared DXBC resource " + decimal(slot));
    return found->second;
}

struct Buffer {
    Str pointer;
    Str size;
    uint32_t stride;
    uint32_t type;
    Dim dim;
    bool shared;
    bool uav;
};

enum class Scope { If, Else, Loop, Switch, Case };

class Emitter {
public:
    Emitter(const Program &program, DxbcTranslateResult &result, const Options &options)
        : p(program), result(result), options(options) {}
    Str emit();

private:
    const Program &p;
    DxbcTranslateResult &result;
    Options options;
    Writer out;
    std::vector<IoField> inputs;
    std::vector<IoField> outputs;
    std::vector<Scope> scopes;
    std::vector<Str> params;
    unsigned clip_count = 0;

    void build_io();
    void add_io(const DxbcSigElem &sig, bool output);
    void add_special(const SpecialIo &field);
    void define_struct(View name, const std::vector<IoField> &fields);
    void bind_parameters();
    void initialize_registers();
    void emit_return();
    void instruction(const Instruction &i);
    bool arithmetic(const Instruction &i);
    bool flow(const Instruction &i);
    bool texture(const Instruction &i);
    bool memory(const Instruction &i);
    void sample(const Instruction &i);
    void texture_read(const Instruction &i);
    void texture_write(const Instruction &i);
    void texture_info(const Instruction &i);
    void sample_position(const Instruction &i);
    void buffer_op(const Instruction &i, bool load, bool structured);
    void atomic(const Instruction &i);
    void texture_atomic(const Instruction &i, const Operand &uav, const Resource &r, View method,
                        bool returns, bool compare, bool signed_order);
    void sync(const Instruction &i);
    Buffer buffer(const Operand &arg) const;
    Str value(const Operand &arg, char type = 'u') const;
    Str scalar(const Operand &arg, char type = 'u') const;
    Str double_bits(const Operand &arg) const;
    Str reg(const Operand &arg, bool destination = false) const;
    Str index(const Operand &arg, size_t i) const;
    Str offset(const Instruction &i, unsigned width) const;
    Str byte_address(const Buffer &b, View element, View byte_offset) const;
    Str condition(const Instruction &i) const;
    void assign(const Instruction &i, unsigned dest, View expression, char type = 'u');
    void assign_pair(const Instruction &i, Str first, Str second, char type = 'u');
    void close_scope(Scope expected);
};

void Emitter::add_io(const DxbcSigElem &sig, bool output) {
    auto semantic = uppercase(sig.semantic_name);
    if (View named = system_name(sig.sys_value_type); !named.empty()) semantic = named;
    if (!sig.mask) return;
    if (!output && sig.register_idx < 32) {
        auto live = p.input.find(sig.register_idx);
        if (live == p.input.end() || !(live->second.mask & sig.mask)) return;
    }
    for (const auto &field : special_fields) {
        if (field.output == output && semantic == field.semantic) {
            // Special operands and ordinary vN/oN declarations use different storage.
            if (sig.register_idx >= 32 || p.special.contains(field.reg)) {
                add_special(field);
                return;
            }
        }
    }
    if (sig.register_idx >= 32)
        throw Error("DXBC stage I/O register out of range for " + semantic);
    if (!output && p.stage == 5)
        throw Error("unsupported compute signature semantic " + semantic);

    IoField f;
    f.reg = (output ? "dx_o[" : "dx_v[") + decimal(sig.register_idx) + "]";
    f.mask = sig.mask;
    f.name = (output ? "out_" : "in_") + decimal(output ? outputs.size() : inputs.size());
    bool integer = sig.component_type == 1 || sig.component_type == 2;
    f.type = scalar_type(sig.component_type) + "4";
    if (semantic == "SV_POSITION" && (output || p.stage == 0)) {
        f.attribute = "position";
        f.type = "float4";
        f.register_aligned = true;
    } else if (!output && ((p.stage == 1 && (semantic == "SV_VERTEXID" || semantic == "SV_INSTANCEID")) ||
                           (p.stage == 0 && (semantic == "SV_PRIMITIVEID" || semantic == "SV_ISFRONTFACE" ||
                                            semantic == "SV_SAMPLEINDEX" || semantic == "SV_COVERAGE")))) {
        if (semantic == "SV_VERTEXID") f.attribute = "vertex_id";
        if (semantic == "SV_INSTANCEID") f.attribute = "instance_id";
        if (semantic == "SV_PRIMITIVEID") f.attribute = "primitive_id";
        if (semantic == "SV_ISFRONTFACE") f.attribute = "front_facing";
        if (semantic == "SV_SAMPLEINDEX") f.attribute = "sample_id";
        if (semantic == "SV_COVERAGE") f.attribute = "sample_mask";
        f.scalar = f.builtin_argument = true;
        f.front = semantic == "SV_ISFRONTFACE";
        f.type = f.front ? "bool" : "uint";
    } else if ((output || p.stage == 0) &&
               (semantic == "SV_RENDERTARGETARRAYINDEX" || semantic == "SV_VIEWPORTARRAYINDEX")) {
        f.attribute = semantic == "SV_RENDERTARGETARRAYINDEX" ? "render_target_array_index" : "viewport_array_index";
        f.scalar = true;
        f.type = "uint";
    } else if (output && p.stage == 0) {
        if (semantic == "SV_DEPTH" || semantic == "SV_DEPTHGREATEREQUAL" || semantic == "SV_DEPTHLESSEQUAL" ||
            semantic == "SV_COVERAGE" || semantic == "SV_STENCILREF") {
            f.scalar = true;
            f.type = semantic.starts_with("SV_DEPTH") ? "float" : "uint";
            if (semantic == "SV_DEPTH") f.attribute = "depth(any)";
            if (semantic == "SV_DEPTHGREATEREQUAL") f.attribute = "depth(greater)";
            if (semantic == "SV_DEPTHLESSEQUAL") f.attribute = "depth(less)";
            if (semantic == "SV_COVERAGE") f.attribute = "sample_mask";
            if (semantic == "SV_STENCILREF") f.attribute = "stencil";
        } else {
            uint32_t color = semantic == "SV_TARGET" ? sig.semantic_index : sig.register_idx;
            if (color >= 8) throw Error("DXBC color output index exceeds Metal limit");
            f.attribute = "color(" + decimal(color) + ")";
            f.register_aligned = true;
        }
    } else if (!output && p.stage == 1) {
        f.name = "vs_v" + decimal(sig.register_idx);
        f.attribute = "attribute(" + decimal(sig.register_idx) + ")";
        f.register_aligned = true;
        auto &m = result.bindings;
        const uint32_t bit = uint32_t(1) << sig.register_idx;
        const uint8_t type = integer ? sig.component_type : 0;
        if (m.vs_input_mask & bit) {
            if (m.vs_input_types[sig.register_idx] != type)
                throw Error("mixed types in a DXBC vertex attribute");
            for (auto &existing : inputs) {
                if (existing.name == f.name) {
                    existing.mask |= f.mask;
                    return;
                }
            }
        }
        m.vs_input_mask |= bit;
        m.vs_input_types[sig.register_idx] = type;
    } else {
        if (semantic == "SV_CULLDISTANCE")
            throw Error("DXBC primitive cull distances require a geometry expansion pass");
        if (semantic == "SV_CLIPDISTANCE" && output) {
            if (sig.semantic_index > 1) throw Error("DXBC clip distance index exceeds D3D11 limits");
            f.clip_base = sig.semantic_index * 4;
            clip_count = std::max<unsigned>(clip_count, f.clip_base + lanes_for_mask(f.mask).size());
        }
        if (semantic.starts_with("SV_") && semantic != "SV_CLIPDISTANCE" &&
            semantic != "SV_VERTEXID" && semantic != "SV_INSTANCEID")
            throw Error("unsupported stage semantic " + semantic);
        if (!identifier(semantic))
            throw Error("invalid DXBC varying semantic " + semantic);
        if (options.force_float4_varyings || f.clip_base >= 0)
            f.type = "float4";
        f.attribute = "user(" + semantic + decimal(sig.semantic_index) + ")";
        if (!output) {
            auto d = p.input.find(sig.register_idx);
            unsigned mode = d == p.input.end() ? 0 : d->second.interpolation_for(sig.mask);
            f.attribute += interpolation(mode, integer);
        }
    }
    (output ? outputs : inputs).push_back(std::move(f));
}

void Emitter::add_special(const SpecialIo &field) {
    auto &fields = field.output ? outputs : inputs;
    const Str name = "arg_" + Str(field.name);
    if (std::any_of(fields.begin(), fields.end(), [&](const IoField &f) { return f.name == name; }))
        return;
    bool scalar = field.type != "uint3";
    fields.push_back({name, Str(field.attribute), Str(field.type), special_register(field.reg),
                      uint8_t(scalar ? 1 : 7), !field.output, scalar, false});
}

void Emitter::build_io() {
    auto append = [&](const auto &signature, const auto &declarations, bool output) {
        uint32_t registers = 0;
        for (const auto &sig : signature) {
            add_io(sig, output);
            if (sig.register_idx < 32) registers |= uint32_t(1) << sig.register_idx;
        }
        for (const auto &[slot, decl] : declarations) {
            if (registers & (uint32_t(1) << slot)) continue;
            uint8_t sys = decl.system_for(decl.mask);
            uint8_t interp = decl.interpolation_for(decl.mask);
            auto semantic = system_name(sys);
            bool color = semantic.empty() && output && p.stage == 0;
            if (color) sys = 64;
            bool integer = (sys >= 4 && sys <= 10) || interp == 1;
            DxbcSigElem sig{Str(semantic.empty() ? (color ? "SV_TARGET" : "TEXCOORD") : semantic),
                           slot, slot, decl.mask, sys, uint8_t(integer ? 1 : 3)};
            add_io(sig, output);
        }
    };
    append(result.inputs, p.input, false);
    append(result.outputs, p.output, true);
    for (const auto &field : special_fields)
        if (p.special.contains(field.reg)) add_special(field);
    if (p.special.contains(Reg::InnerCoverage))
        throw Error("DXBC conservative raster inner coverage has no Metal builtin");
    if (p.stage == 1 && std::none_of(outputs.begin(), outputs.end(),
                                    [](const IoField &f) { return f.attribute == "position"; })) {
        throw Error("DXBC vertex shader has no SV_Position output");
    }
}

void Emitter::define_struct(View name, const std::vector<IoField> &fields) {
    if (std::none_of(fields.begin(), fields.end(), [](const IoField &f) { return !f.builtin_argument; }))
        return;
    out.open("struct " + Str(name));
    if (name == "VSOut" && clip_count)
        out.line("float dx_clip_distance [[clip_distance]] [" + decimal(clip_count) + "];");
    for (const auto &f : fields)
        if (!f.builtin_argument)
            out.line(f.type + " " + f.name + " [[" + f.attribute + "]];");
    out.close(";");
}

void Emitter::bind_parameters() {
    auto binding = [&](View type, View name, View space, unsigned slot) {
        params.push_back(Str(type) + (type.ends_with('*') ? "" : " ") + Str(name) + " [[" + Str(space) +
                         "(" + decimal(slot) + ")]]");
    };
    if (std::any_of(inputs.begin(), inputs.end(), [](const IoField &f) { return !f.builtin_argument; }))
        params.emplace_back(p.stage == 1 ? "VSIn dx_stage [[stage_in]]" : "PSIn dx_stage [[stage_in]]");
    for (const auto &f : inputs) {
        if (!f.builtin_argument) continue;
        params.push_back(f.type + " " + f.name + " [[" + f.attribute + "]]");
        if (f.attribute == "vertex_id") params.emplace_back("uint dx_base_vertex [[base_vertex]]");
        if (f.attribute == "instance_id") params.emplace_back("uint dx_base_instance [[base_instance]]");
    }
    const auto &m = result.bindings;
    for (const auto &[slot, size] : p.cb)
        binding("constant float4 *", register_name("cb", slot), "buffer", m.cb[slot]);
    for (const auto &[slot, r] : p.srv)
        binding(r.buffer() ? "const device uint *" : texture_type(r, false), register_name("t", slot),
                r.buffer() ? "buffer" : "texture", m.srv[slot] & BO3_BIND_IDX_MASK);
    for (const auto &[slot, r] : p.uav) {
        binding(r.buffer() ? "device uint *" : texture_type(r, true), register_name("u", slot),
                r.buffer() ? "buffer" : "texture", m.uav[slot] & BO3_BIND_IDX_MASK);
        if (m.uav_counter_idx[slot] != BO3_BIND_UNUSED)
            binding("device atomic_uint *", register_name("u", slot) + "_counter", "buffer",
                    m.uav_counter_idx[slot]);
    }
    for (const auto &[slot, usage] : p.samplers) {
        Str name = register_name("s", slot);
        if (m.smp[slot] != BO3_BIND_UNUSED)
            binding("sampler", name, "sampler", m.smp[slot]);
        if (m.smp_cube[slot] != BO3_BIND_UNUSED)
            binding("sampler", name + "cube", "sampler", m.smp_cube[slot]);
    }
    if (std::any_of(p.instructions.begin(), p.instructions.end(), [](const Instruction &i) {
            return i.op == Op::DERIV_RTX_FINE || i.op == Op::DERIV_RTY_FINE;
        })) params.emplace_back("uint dx_quad_lane [[thread_index_in_quadgroup]]");
    if (m.buffer_info_buf != BO3_BIND_UNUSED)
        binding("constant uint *", "bufferInfo", "buffer", m.buffer_info_buf);
}

void Emitter::initialize_registers() {
    if (p.temps) out.line("uint4 dx_r[" + decimal(p.temps) + "] = {};");
    if (p.stage != 5) {
        out.line("uint4 dx_v[32] = {};");
        out.line("uint4 dx_o[32] = {};");
    }
    for (auto [slot, size] : p.indexed)
        out.line("uint4 " + register_name("x", slot) + "[" + decimal(size) + "] = {};");
    for (const auto &[slot, r] : p.shared)
        out.line("threadgroup uint " + register_name("g", slot) + "[" + decimal(r.bytes / 4) + "];");
    for (const auto &f : outputs) {
        if (f.reg.find('[') == Str::npos)
            out.line("uint4 " + f.reg + " = uint4(0u);");
    }
    for (const auto &f : inputs) {
        Str src = f.builtin_argument ? f.name : "dx_stage." + f.name;
        uint8_t mask = f.mask;
        if (f.attribute == "vertex_id") src = paren(src + " - dx_base_vertex");
        if (f.attribute == "instance_id") src = paren(src + " - dx_base_instance");
        if (p.stage == 0 && f.attribute == "position" && (mask & 8)) {
            out.line(f.reg + ".w = " + bits("uint", "1.0f / " + src + ".w") + ";");
            mask &= 7;
            if (!mask) continue;
        }
        if (f.front) src = paren(src + " ? ~0u : 0u");
        else if (f.type.starts_with("float") || f.type.starts_with("int"))
            src = bits(f.scalar ? "uint" : "uint4", src);
        if (f.reg.find('[') == Str::npos) {
            if (f.type == "uint3") src = call("uint4", {src, "0u"});
            else src = call("uint4", {src});
            out.line("uint4 " + f.reg + " = " + src + ";");
        } else {
            Str lanes = lanes_for_mask(mask);
            if (f.scalar) {
                if (lanes.size() > 1) src = cast(vector_type("uint", lanes.size()), src);
            } else if (lanes.size() < 4) {
                Str fields = f.register_aligned ? lanes : Str(xyzw.substr(0, lanes.size()));
                src = member(src, fields);
            }
            out.line(f.reg + "." + lanes + " = " + src + ";");
        }
    }
}

void Emitter::emit_return() {
    if (outputs.empty()) {
        out.line("return;");
        return;
    }
    out.open("");
    out.line(Str(p.stage == 1 ? "VSOut" : "PSOut") + " dx_return = {};");
    for (const auto &f : outputs) {
        Str lanes = lanes_for_mask(f.mask);
        if (f.scalar) lanes.resize(1);
        Str src = f.register_aligned ? f.reg : member(f.reg, lanes);
        if (!f.scalar && !f.register_aligned && lanes.size() < 4) {
            Str args = src;
            for (size_t j = lanes.size(); j < 4; ++j) args += ", 0u";
            src = "uint4(" + args + ")";
        }
        if (f.type != "uint" && f.type != "uint4") src = bits(f.type, src);
        out.line("dx_return." + f.name + " = " + src + ";");
        if (f.clip_base >= 0) {
            for (size_t lane = 0; lane < lanes.size(); ++lane)
                out.line("dx_return.dx_clip_distance[" + decimal(f.clip_base + lane) + "] = dx_return." +
                         f.name + "." + xyzw[lane] + ";");
        }
    }
    out.line("return dx_return;");
    out.close();
}

Str Emitter::index(const Operand &arg, size_t i) const {
    if (i >= arg.indices.size() || arg.indices[i].immediate > UINT32_MAX)
        throw Error("invalid DXBC register index");
    const auto &idx = arg.indices[i];
    Str base = unsigned_literal(idx.immediate);
    if (!idx.relative) return base;
    Str relative = scalar(*idx.relative);
    return idx.immediate ? paren(base + " + " + relative) : relative;
}

Str Emitter::reg(const Operand &arg, bool destination) const {
    auto array = [&](View name, size_t dim, uint32_t size) {
        Str subscript = index(arg, dim);
        if (!size) throw Error("undeclared DXBC register bank");
        if (!arg.indices[dim].relative) {
            if (arg.indices[dim].immediate >= size) {
                if (!destination) return Str("uint4(0u)");
                throw Error("DXBC destination register index out of range");
            }
            return Str(name) + "[" + subscript + "]";
        }
        if (destination) return Str(name) + "[" + subscript + "]";
        return paren(subscript + " < " + unsigned_literal(size) + " ? " +
                     Str(name) + "[" + subscript + "] : uint4(0u)");
    };
    switch (arg.reg) {
    case Reg::Temp: return array("dx_r", 0, p.temps);
    case Reg::Input:
        if (destination || p.stage == 5) throw Error("invalid DXBC input register use");
        return array("dx_v", 0, 32);
    case Reg::Output:
        if (p.stage == 5) throw Error("compute shader has no output registers");
        return array("dx_o", 0, 32);
    case Reg::Indexable: {
        auto found = p.indexed.find(arg.slot());
        if (found == p.indexed.end())
            throw Error("undeclared DXBC indexable temp register");
        return array(register_name("x", arg.slot()), 1, found->second);
    }
    case Reg::Cb: {
        if (destination) throw Error("cannot write DXBC constant buffer");
        auto slot = arg.slot();
        auto found = p.cb.find(slot);
        if (found == p.cb.end())
            throw Error("undeclared DXBC constant buffer " + decimal(slot));
        if (!found->second)
            throw Error("missing DXBC constant buffer size for cb" + decimal(slot));
        Str subscript = index(arg, 1);
        return paren(subscript + " < " + unsigned_literal(found->second) + " ? " +
                     bits("uint4", register_name("cb", slot) + "[" + subscript + "]") +
                     " : uint4(0u)");
    }
    case Reg::Icb:
        if (destination) throw Error("cannot write DXBC immediate constant buffer");
        return array("dx_icb_data", 0, p.icb.size() / 4);
    case Reg::Depth: case Reg::DepthGE: case Reg::DepthLE: case Reg::Stencil: case Reg::OutputCoverage:
        return special_register(arg.reg);
    case Reg::Thread: case Reg::Group: case Reg::LocalThread: case Reg::LocalIndex:
    case Reg::Primitive: case Reg::InputCoverage:
        if (destination) throw Error("cannot write DXBC system input");
        return special_register(arg.reg);
    default: throw Error("unsupported DXBC register type " + decimal(unsigned(arg.reg)));
    }
}

Str Emitter::double_bits(const Operand &arg) const {
    Str raw;
    if (arg.reg == Reg::Imm64) {
        auto v = [&](unsigned lane) { return unsigned_literal(arg.literal[lane]); };
        raw = call("uint4", {v(0), v(1), v(arg.components == 1 ? 0 : 2),
                             v(arg.components == 1 ? 1 : 3)});
    } else {
        raw = swizzle(arg, reg(arg));
    }
    constexpr View sign = "uint4(0u, 0x80000000u, 0u, 0x80000000u)";
    if (arg.modifier & 2) raw = paren(raw + " & ~" + Str(sign));
    if (arg.modifier & 1) raw = paren(raw + " ^ " + Str(sign));
    return raw;
}

Str Emitter::value(const Operand &arg, char type) const {
    Str raw;
    if (arg.reg == Reg::Imm32) {
        raw = "uint4(";
        for (unsigned j = 0; j < arg.components; ++j) {
            if (j) raw += ", ";
            raw += unsigned_literal(arg.literal[j]);
        }
        raw += ')';
    } else if (arg.reg == Reg::Imm64) {
        throw Error("64-bit DXBC arithmetic requires double precision");
    } else {
        raw = swizzle(arg, reg(arg));
    }
    if (type == 'f' || (arg.modifier && type == 'u')) {
        Str result = bits("float4", raw);
        if (arg.modifier & 2) result = call("abs", {result});
        if (arg.modifier & 1) result = "-" + paren(result);
        return type == 'u' ? bits("uint4", result) : result;
    }
    if (type == 'i' || type == 'b') {
        if (arg.modifier & 2) raw = call("dx_iabs", {raw});
        if (arg.modifier & 1) raw = "(-" + raw + ")";
        return type == 'i' ? bits("int4", raw) : raw;
    }
    return raw;
}

Str Emitter::scalar(const Operand &arg, char type) const {
    return member(value(arg, type), "x");
}

void Emitter::assign(const Instruction &i, unsigned dest, View expression, char type) {
    const auto &arg = i.args[dest];
    if (arg.reg == Reg::Null) return;
    Str lanes = lanes_for_mask(arg.mask);
    if (lanes.empty() || arg.modifier)
        throw Error("invalid DXBC destination mask or modifier");
    Str target = reg(arg, true);
    Str rhs(expression);
    if (i.token & 0x2000) {
        Str floats = type == 'f' ? rhs : bits("float4", rhs);
        rhs = call("dx_saturate", {floats});
        type = 'f';
    }
    if (type != 'u') rhs = bits("uint4", rhs);
    if (lanes != xyzw) {
        target += "." + lanes;
        rhs = member(rhs, lanes);
    }

    size_t subscript = arg.reg == Reg::Indexable ? 1 : 0;
    if (arg.indices.size() > subscript && arg.indices[subscript].relative) {
        uint32_t count = arg.reg == Reg::Temp ? p.temps :
                         arg.reg == Reg::Indexable ? p.indexed.at(arg.slot()) : 32;
        out.open("if (" + index(arg, subscript) + " < " + unsigned_literal(count) + ")");
        out.line(target + " = " + rhs + ";");
        out.close();
    } else {
        out.line(target + " = " + rhs + ";");
    }
}

void Emitter::assign_pair(const Instruction &i, Str first, Str second, char type) {
    out.open("");
    auto vector = type == 'f' ? "float4" : type == 'i' ? "int4" : "uint4";
    // Snapshot both results before either destination can alias a source register.
    if (i.args[0].reg != Reg::Null) out.line(Str(vector) + " dx_first = " + first + ";");
    if (i.args[1].reg != Reg::Null) out.line(Str(vector) + " dx_second = " + second + ";");
    assign(i, 0, "dx_first", type);
    assign(i, 1, "dx_second", type);
    out.close();
}

bool Emitter::arithmetic(const Instruction &i) {
    auto unary = [&](char type, View function, char result_type) {
        i.count(2);
        assign(i, 0, call(function, {value(i.args[1], type)}), result_type);
    };
    auto binary = [&](char type, View operation, bool function = false, bool compare = false) {
        i.count(3);
        Str a = value(i.args[1], type), b = value(i.args[2], type);
        Str expression = function ? call(operation, {a, b}) : paren(a + " " + Str(operation) + " " + b);
        if (compare) expression = call("select", {"uint4(0u)", "uint4(~0u)", expression});
        assign(i, 0, expression, compare || type == 'b' ? 'u' : type);
    };
    auto shifted = [&](char type, View operation) {
        i.count(3);
        Str shift = paren(value(i.args[2], 'b') + " & uint4(31u)");
        if (type == 'i') shift = cast("int4", shift);
        assign(i, 0, paren(value(i.args[1], type) + " " + Str(operation) + " " + shift), type == 'i' ? 'i' : 'u');
    };
    auto op_call = [&](char type, View fn, size_t sources, char result_type) {
        i.count(sources + 1);
        Str args;
        for (size_t k = 1; k <= sources; ++k) {
            if (k != 1) args += ", ";
            args += value(i.args[k], type);
        }
        assign(i, 0, Str(fn) + paren(args), result_type);
    };
    switch (i.op) {
    case Op::MOV: i.count(2); assign(i, 0, value(i.args[1])); break;
    case Op::DMOV: i.count(2); assign(i, 0, double_bits(i.args[1])); break;
    case Op::DMOVC: {
        i.count(4);
        Str flags = member(value(i.args[1]), "xxyy") + " != uint4(0u)";
        assign(i, 0, call("select", {double_bits(i.args[3]), double_bits(i.args[2]), flags}));
        break;
    }
    case Op::MOVC: {
        i.count(4);
        auto flags = value(i.args[1]) + " != uint4(0u)";
        assign(i, 0, call("select", {value(i.args[3]), value(i.args[2]), flags}));
        break;
    }
    case Op::SWAPC: {
        i.count(5);
        auto flags = value(i.args[2]) + " != uint4(0u)";
        auto a = value(i.args[3]), b = value(i.args[4]);
        assign_pair(i, call("select", {a, b, flags}), call("select", {b, a, flags}));
        break;
    }
    case Op::ADD: binary('f', "+"); break;
    case Op::MUL: binary('f', "*"); break;
    case Op::DIV: binary('f', "/"); break;
    case Op::MIN: binary('f', "fmin", true); break;
    case Op::MAX: binary('f', "fmax", true); break;
    case Op::MAD: op_call('f', "fma", 3, 'f'); break;
    case Op::DP2: case Op::DP3: case Op::DP4: {
        i.count(3);
        View channels = xyzw.substr(0, 2 + unsigned(i.op) - unsigned(Op::DP2));
        assign(i, 0, cast("float4", call("dot", {member(value(i.args[1], 'f'), channels),
                                                  member(value(i.args[2], 'f'), channels)})), 'f');
        break;
    }
    case Op::LT: binary('f', "<", false, true); break;
    case Op::GE: binary('f', ">=", false, true); break;
    case Op::EQ: binary('f', "==", false, true); break;
    case Op::NE: binary('f', "!=", false, true); break;
    case Op::SQRT: unary('f', "sqrt", 'f'); break;
    case Op::RSQ: unary('f', "rsqrt", 'f'); break;
    case Op::RCP: unary('f', "dx_rcp", 'f'); break;
    case Op::LOG: unary('f', "log2", 'f'); break;
    case Op::EXP: unary('f', "exp2", 'f'); break;
    case Op::FRC: unary('f', "fract", 'f'); break;
    case Op::ROUND_NE: unary('f', "rint", 'f'); break;
    case Op::ROUND_NI: unary('f', "floor", 'f'); break;
    case Op::ROUND_PI: unary('f', "ceil", 'f'); break;
    case Op::ROUND_Z: unary('f', "trunc", 'f'); break;
    case Op::SINCOS: {
        i.count(3);
        auto src = value(i.args[2], 'f');
        assign_pair(i, call("sin", {src}), call("cos", {src}), 'f');
        break;
    }
    case Op::DERIV_RTX: case Op::DERIV_RTY:
        if (p.stage != 0) throw Error("DXBC derivatives require a pixel shader");
        unary('f', i.op == Op::DERIV_RTX ? "dfdx" : "dfdy", 'f');
        break;
    case Op::DERIV_RTX_COARSE: case Op::DERIV_RTY_COARSE:
    case Op::DERIV_RTX_FINE: case Op::DERIV_RTY_FINE: {
        if (p.stage != 0) throw Error("DXBC derivatives require a pixel shader");
        i.count(2);
        bool fine = i.op == Op::DERIV_RTX_FINE || i.op == Op::DERIV_RTY_FINE;
        bool x = i.op == Op::DERIV_RTX_FINE || i.op == Op::DERIV_RTX_COARSE;
        Str src = value(i.args[1], 'f');
        Str step = x ? "1u" : "2u";
        if (fine) {
            Str other = call("quad_shuffle_xor", {src, cast("ushort", step)});
            Str positive = paren(other + " - " + src);
            Str negative = paren(src + " - " + other);
            assign(i, 0, paren("(dx_quad_lane & " + step + ") != 0u ? " + negative + " : " + positive), 'f');
        } else {
            Str right = call("quad_broadcast", {src, cast("ushort", step)});
            Str left = call("quad_broadcast", {src, "ushort(0)"});
            assign(i, 0, paren(right + " - " + left), 'f');
        }
        break;
    }
    case Op::F32TOF16: unary('f', "dx_f32tof16", 'u'); break;
    case Op::F16TOF32: unary('b', "dx_f16tof32", 'f'); break;
    case Op::FTOI: unary('f', "dx_ftoi", 'i'); break;
    case Op::FTOU: unary('f', "dx_ftou", 'u'); break;
    case Op::ITOF: unary('i', "float4", 'f'); break;
    case Op::UTOF: unary('b', "float4", 'f'); break;
    case Op::IADD: binary('b', "+"); break;
    case Op::INEG:
        i.count(2); assign(i, 0, "-" + paren(value(i.args[1], 'b'))); break;
    case Op::IMIN: binary('i', "min", true); break;
    case Op::IMAX: binary('i', "max", true); break;
    case Op::UMIN: binary('b', "min", true); break;
    case Op::UMAX: binary('b', "max", true); break;
    case Op::IEQ: binary('b', "==", false, true); break;
    case Op::INE: binary('b', "!=", false, true); break;
    case Op::IGE: binary('i', ">=", false, true); break;
    case Op::ILT: binary('i', "<", false, true); break;
    case Op::UGE: binary('b', ">=", false, true); break;
    case Op::ULT: binary('b', "<", false, true); break;
    case Op::ISHL: shifted('b', "<<"); break;
    case Op::ISHR: shifted('i', ">>"); break;
    case Op::USHR: shifted('b', ">>"); break;
    case Op::AND: binary('b', "&"); break;
    case Op::OR: binary('b', "|"); break;
    case Op::XOR: binary('b', "^"); break;
    case Op::NOT:
        i.count(2); assign(i, 0, "~" + paren(value(i.args[1], 'b'))); break;
    case Op::IMUL: case Op::UMUL: {
        i.count(4);
        bool sign = i.op == Op::IMUL;
        auto a = value(i.args[2], sign ? 'i' : 'b');
        auto b = value(i.args[3], sign ? 'i' : 'b');
        Str high = call("mulhi", {a, b});
        if (sign) {
            high = bits("uint4", high);
            a = bits("uint4", a);
            b = bits("uint4", b);
        }
        assign_pair(i, high, paren(a + " * " + b));
        break;
    }
    case Op::UDIV: case Op::UADDC: case Op::USUBB: {
        i.count(4);
        auto a = value(i.args[2], 'b'), b = value(i.args[3], 'b');
        if (i.op == Op::UDIV) {
            assign_pair(i, call("dx_udiv", {a, b}), call("dx_umod", {a, b}));
        } else if (i.op == Op::UADDC) {
            assign_pair(i, paren(a + " + " + b), cast("uint4", paren(paren(a + " + " + b) + " < " + a)));
        } else {
            assign_pair(i, paren(a + " - " + b), cast("uint4", paren(a + " < " + b)));
        }
        break;
    }
    case Op::IMAD: op_call('b', "dx_mad", 3, 'u'); break;
    case Op::UMAD: op_call('b', "dx_mad", 3, 'u'); break;
    case Op::BFI: op_call('b', "dx_bfi", 4, 'u'); break;
    case Op::UBFE: op_call('b', "dx_ubfe", 3, 'u'); break;
    case Op::IBFE: op_call('b', "dx_ibfe", 3, 'u'); break;
    case Op::BFREV: unary('b', "reverse_bits", 'u'); break;
    case Op::COUNTBITS: unary('b', "popcount", 'u'); break;
    case Op::FIRSTBIT_HI: unary('b', "dx_first_hi", 'u'); break;
    case Op::FIRSTBIT_LO: unary('b', "dx_first_lo", 'u'); break;
    case Op::FIRSTBIT_SHI: unary('b', "dx_first_shi", 'u'); break;
    default: return false;
    }
    return true;
}

Str Emitter::condition(const Instruction &i) const {
    i.count(1);
    return paren(scalar(i.args[0]) + ((i.token & (1u << 18)) ? " != 0u" : " == 0u"));
}

void Emitter::close_scope(Scope expected) {
    if (scopes.empty() || scopes.back() != expected)
        throw Error("mismatched DXBC control-flow block");
    scopes.pop_back();
    out.close();
}

bool Emitter::flow(const Instruction &i) {
    auto has = [&](Scope scope) {
        return std::find(scopes.begin(), scopes.end(), scope) != scopes.end();
    };
    auto open_if = [&]() { out.open("if " + condition(i)); };
    switch (i.op) {
    case Op::NOP: i.count(0); break;
    case Op::IF: open_if(); scopes.push_back(Scope::If); break;
    case Op::ELSE:
        i.count(0); close_scope(Scope::If); out.open("else"); scopes.push_back(Scope::Else); break;
    case Op::ENDIF:
        i.count(0); close_scope(!scopes.empty() && scopes.back() == Scope::Else ? Scope::Else : Scope::If);
        break;
    case Op::LOOP:
        i.count(0); out.open("while (true)"); scopes.push_back(Scope::Loop); break;
    case Op::ENDLOOP: i.count(0); close_scope(Scope::Loop); break;
    case Op::BREAK: case Op::BREAKC:
        if (!has(Scope::Loop) && !has(Scope::Switch))
            throw Error("DXBC break outside loop or switch");
        if (i.op == Op::BREAKC) open_if();
        else i.count(0);
        out.line("break;");
        if (i.op == Op::BREAKC) out.close();
        break;
    case Op::CONTINUE: case Op::CONTINUEC:
        if (!has(Scope::Loop)) throw Error("DXBC continue outside loop");
        if (i.op == Op::CONTINUEC) open_if();
        else i.count(0);
        out.line("continue;");
        if (i.op == Op::CONTINUEC) out.close();
        break;
    case Op::SWITCH:
        i.count(1); out.open("switch " + paren(scalar(i.args[0]))); scopes.push_back(Scope::Switch);
        break;
    case Op::CASE: case Op::DEFAULT: {
        if (!scopes.empty() && scopes.back() == Scope::Case) close_scope(Scope::Case);
        if (scopes.empty() || scopes.back() != Scope::Switch)
            throw Error("DXBC case outside switch");
        if (i.op == Op::CASE) {
            i.count(1);
            const auto &c = i.args[0];
            if (c.reg != Reg::Imm32 || c.modifier || c.components != 1)
                throw Error("DXBC case requires a scalar integer literal");
            out.open("case " + unsigned_literal(c.literal[0]) + ":");
        } else {
            i.count(0); out.open("default:");
        }
        scopes.push_back(Scope::Case);
        break;
    }
    case Op::ENDSWITCH:
        i.count(0);
        if (!scopes.empty() && scopes.back() == Scope::Case) close_scope(Scope::Case);
        close_scope(Scope::Switch);
        break;
    case Op::RET: i.count(0); emit_return(); break;
    case Op::RETC: open_if(); emit_return(); out.close(); break;
    case Op::DISCARD:
        if (p.stage != 0) throw Error("DXBC discard requires a pixel shader");
        open_if(); out.line("discard_fragment();"); out.close(); break;
    default: return false;
    }
    return true;
}

Str Emitter::offset(const Instruction &i, unsigned width) const {
    if (width == 1) return std::to_string(i.offset[0]);
    Str result = vector_type("int", width) + "(";
    for (unsigned j = 0; j < width; ++j) {
        if (j) result += ", ";
        result += std::to_string(i.offset[j]);
    }
    return result + ")";
}

void Emitter::sample(const Instruction &i) {
    bool gather = i.op == Op::GATHER4 || i.op == Op::GATHER4_C ||
                  i.op == Op::GATHER4_PO || i.op == Op::GATHER4_PO_C;
    bool programmable = i.op == Op::GATHER4_PO || i.op == Op::GATHER4_PO_C;
    bool compare = i.op == Op::SAMPLE_C || i.op == Op::SAMPLE_C_LZ ||
                   i.op == Op::GATHER4_C || i.op == Op::GATHER4_PO_C;
    bool bias = i.op == Op::SAMPLE_B;
    bool level = i.op == Op::SAMPLE_L;
    bool gradient = i.op == Op::SAMPLE_D;
    bool lod = i.op == Op::LOD;
    unsigned resource = programmable ? 3 : 2;
    unsigned extra = resource + 2;
    i.count(extra + (gradient ? 2 : compare || bias || level ? 1 : 0));

    const auto &t = i.args[resource];
    const auto &s = i.args[resource + 1];
    if (t.reg != Reg::Srv || s.reg != Reg::Sampler || !p.samplers.contains(s.slot()))
        throw Error("invalid DXBC texture or sampler operand");
    const auto &r = resource_at(p.srv, t.slot());
    auto d = shape(r.dim);
    Str tex = register_name("t", t.slot());
    Str sampler = register_name("s", s.slot()) + (d.cube ? "cube" : "");
    Str coord = value(i.args[1], 'f');
    Str spatial = member(coord, xyzw.substr(0, d.axes));
    if (d.ms)
        throw Error("DXBC multisample textures require ld_ms");
    if (lod) {
        if (p.stage != 0)
            throw Error("DXBC lod requires a pixel shader");
        Str args = sampler + ", " + spatial;
        Str expression;
        if (d.axes == 1) {
            Str delta = "max(abs(dfdx(" + spatial + ")), abs(dfdy(" + spatial + ")))";
            expression = call("float4", {"0.0f", "log2(" + delta + " * float(" + tex + ".get_width()))",
                                         "0.0f", "0.0f"});
        } else {
            expression = call("float4", {tex + ".calculate_clamped_lod(" + args + ")",
                                         tex + ".calculate_unclamped_lod(" + args + ")",
                                         "0.0f", "0.0f"});
        }
        assign(i, 0, swizzle(t, expression), 'f');
        return;
    }
    bool immediate_offset = i.offset[0] || i.offset[1] || i.offset[2];
    if (d.cube && (immediate_offset || programmable))
        throw Error("DXBC cube textures cannot be sampled with texel offsets");
    if (gather && !d.cube && d.axes != 2)
        throw Error("DXBC gather requires a 2D or cube texture");
    if (programmable) {
        Str raw = member(value(i.args[2], 'b'), "xy");
        Str delta = "float2(as_type<int2>(" + raw + " << 26u) >> 26)";
        Str dimensions = "float2(" + tex + ".get_width(), " + tex + ".get_height())";
        spatial = paren(spatial + " + " + delta + " / " + dimensions);
    }
    if (immediate_offset && d.axes == 1)
        spatial = paren(spatial + " + float(" + offset(i, 1) + ") / float(" + tex + ".get_width())");
    Str args = sampler + ", " + spatial;
    if (d.array) {
        auto array = member(coord, xyzw.substr(d.axes, 1));
        args += ", uint(clamp(rint(" + array + "), 0.0f, float(" + tex + ".get_array_size() - 1u)))";
    }
    if (compare)
        args += ", " + scalar(i.args[extra], 'f');
    if (!gather && d.axes != 1) {
        if (level) {
            args += ", level(" + scalar(i.args[extra], 'f') + ")";
        } else if (gradient) {
            Str gradients = Str(d.cube ? "gradientcube" : d.axes == 3 ? "gradient3d" : "gradient2d");
            View lanes = xyzw.substr(0, d.axes);
            args += ", " + call(gradients, {member(value(i.args[extra], 'f'), lanes),
                                            member(value(i.args[extra + 1], 'f'), lanes)});
        } else if (i.op == Op::SAMPLE_C_LZ || p.stage != 0) {
            args += ", level(0.0f)";
        } else if (bias) {
            args += ", bias(" + scalar(i.args[extra], 'f') + ")";
        }
    }
    if (!d.cube && d.axes > 1 && (immediate_offset || gather)) {
        args += ", " + offset(i, d.axes);
    }
    if (gather && !compare && !r.comparison)
        args += ", component::" + Str(1, xyzw[s.swizzle[0]]);
    View method = gather ? (compare ? "gather_compare" : "gather") :
                          (compare ? "sample_compare" : "sample");
    Str expression = tex + "." + Str(method) + paren(args);
    char type = r.type == 3 ? 'i' : r.type == 4 ? 'u' : 'f';
    if (!gather && (compare || r.comparison)) {
        expression = compare ? cast("float4", expression) : "float4(" + expression + ", 0.0f, 0.0f, 1.0f)";
        type = 'f';
    }
    assign(i, 0, swizzle(t, expression), type);
}

void Emitter::texture_read(const Instruction &i) {
    bool ms = i.op == Op::LD_MS;
    bool uav = i.op == Op::LD_UAV_TYPED;
    i.count(ms ? 4 : 3);
    const auto &t = i.args[2];
    if (t.reg != (uav ? Reg::Uav : Reg::Srv))
        throw Error("invalid DXBC texture load operand");
    const auto &r = resource_at(uav ? p.uav : p.srv, t.slot());
    if (r.buffer()) {
        if (ms || r.dim != Dim::Buffer) throw Error("invalid typed DXBC buffer load");
        auto b = buffer(t);
        out.open("");
        out.line("uint4 dx_load = uint4(0u);");
        out.line("uint dx_element = " + scalar(i.args[1]) + ";");
        out.open("if (dx_element < " + b.size + ")");
        out.line("uint dx_width = min(" + b.pointer + "_stride / 4u, 4u);");
        out.line("ulong dx_base = ulong(dx_element) * (" + b.pointer + "_stride / 4u);");
        out.line("dx_load.w = " + Str(r.type == 3 || r.type == 4 ? "1u;" : "0x3f800000u;"));
        out.open("for (uint dx_lane = 0; dx_lane < dx_width; ++dx_lane)");
        out.line("dx_load[dx_lane] = " + b.pointer + "[dx_base + dx_lane];");
        out.close();
        out.close();
        assign(i, 0, swizzle(t, "dx_load"));
        out.close();
        return;
    }
    auto d = shape(r.dim);
    if (d.ms != ms || d.cube)
        throw Error("invalid DXBC texture dimension for ld/ld_ms");
    Str tex = register_name(uav ? "u" : "t", t.slot());
    auto width = vector_type("uint", d.axes);
    out.open("");
    out.line("int4 dx_coord = " + value(i.args[1], 'i') + ";");
    Str coord = member("dx_coord", xyzw.substr(0, d.axes));
    bool has_offset = i.offset[0] || i.offset[1] || i.offset[2];
    if (has_offset) coord = paren(coord + " + " + offset(i, d.axes));
    out.line(width + " dx_read_coord = " + cast(width, coord) + ";");
    bool mips = !d.ms && !uav && d.axes > 1;
    if (mips) {
        out.line("uint dx_mip = uint(dx_coord.w);");
    }
    if (d.array)
        out.line("uint dx_slice = uint(dx_coord." + Str(1, xyzw[d.axes]) + ");");
    if (ms)
        out.line("uint dx_sample = " + scalar(i.args[3]) + ";");

    Str mip = mips ? "dx_mip" : "";
    Str check = mips ? "dx_mip < " + tex + ".get_num_mip_levels() && " : "";
    if (!mips && !ms && !uav && d.axes == 1)
        check += "dx_coord.w == 0 && ";
    constexpr View queries[] = {"get_width", "get_height", "get_depth"};
    for (unsigned j = 0; j < d.axes; ++j) {
        if (j) check += " && ";
        check += "dx_read_coord";
        if (d.axes != 1) check += "." + Str(1, xyzw[j]);
        check += " < " + tex + "." + Str(queries[j]) + paren(mip);
    }
    if (d.array) check += " && dx_slice < " + tex + ".get_array_size()";
    if (ms) check += " && dx_sample < " + tex + ".get_num_samples()";
    Str args = "dx_read_coord";
    if (d.array) args += ", dx_slice";
    if (ms) args += ", dx_sample";
    if (mips) args += ", dx_mip";
    Str expression = tex + ".read" + paren(args);
    char type = r.type == 3 ? 'i' : r.type == 4 ? 'u' : 'f';
    Str vector = type == 'i' ? "int4" : type == 'u' ? "uint4" : "float4";
    if (r.comparison) expression = "float4(" + expression + ", 0.0f, 0.0f, 1.0f)";
    assign(i, 0, swizzle(t, paren(check + " ? " + expression + " : " + cast(vector, "0"))), type);
    out.close();
}

void Emitter::texture_write(const Instruction &i) {
    i.count(3);
    const auto &u = i.args[0];
    if (u.reg != Reg::Uav)
        throw Error("invalid DXBC typed UAV store operand");
    const auto &r = resource_at(p.uav, u.slot());
    if (r.buffer()) {
        if (r.dim != Dim::Buffer) throw Error("invalid typed DXBC buffer store");
        auto b = buffer(u);
        out.open("");
        out.line("uint dx_element = " + scalar(i.args[1]) + ";");
        out.open("if (dx_element < " + b.size + ")");
        out.line("uint dx_width = min(" + b.pointer + "_stride / 4u, 4u);");
        out.line("ulong dx_base = ulong(dx_element) * (" + b.pointer + "_stride / 4u);");
        out.line("uint4 dx_data = " + value(i.args[2]) + ";");
        out.open("for (uint dx_lane = 0; dx_lane < dx_width; ++dx_lane)");
        out.line(b.pointer + "[dx_base + dx_lane] = dx_data[dx_lane];");
        out.close();
        out.close();
        out.close();
        return;
    }
    auto d = shape(r.dim);
    if (d.ms || d.cube)
        throw Error("invalid DXBC UAV store dimension");
    Str tex = register_name("u", u.slot());
    out.open("");
    out.line("uint4 dx_coord = " + value(i.args[1]) + ";");
    Str args = value(i.args[2], r.type == 3 ? 'i' : r.type == 4 ? 'u' : 'f');
    args += ", " + member("dx_coord", xyzw.substr(0, d.axes));
    if (d.array) args += ", dx_coord." + Str(1, xyzw[d.axes]);
    out.open("if " + paren(texel_bounds(tex, "dx_coord", d)));
    out.line(tex + ".write" + paren(args) + ";");
    out.close();
    out.close();
}

void Emitter::texture_info(const Instruction &i) {
    bool resinfo = i.op == Op::RESINFO;
    i.count(resinfo ? 3 : 2);
    const auto &arg = i.args[resinfo ? 2 : 1];
    if (!resinfo) {
        Str count;
        if (arg.reg == Reg::Rasterizer) {
            if (p.stage != 0)
                throw Error("DXBC rasterizer sampleinfo requires a pixel shader");
            count = "get_num_samples()";
        } else {
            if (arg.reg != Reg::Srv) throw Error("invalid DXBC sampleinfo operand");
            auto d = shape(resource_at(p.srv, arg.slot()).dim);
            if (!d.ms) throw Error("DXBC sampleinfo requires a multisampled texture");
            count = register_name("t", arg.slot()) + ".get_num_samples()";
        }
        bool integer = (i.token & 0x1800) == 0x800;
        Str result_value = integer ? "uint4(" + count + ", 0u, 0u, 0u)" :
                                     "float4(float(" + count + "), 0.0f, 0.0f, 0.0f)";
        assign(i, 0, swizzle(arg, result_value), integer ? 'u' : 'f');
        return;
    }
    if (arg.reg != Reg::Srv && arg.reg != Reg::Uav)
        throw Error("invalid DXBC resinfo texture operand");
    bool uav = arg.reg == Reg::Uav;
    const auto &r = resource_at(uav ? p.uav : p.srv, arg.slot());
    auto mode = (i.token >> 11) & 3;
    if (mode == 3) throw Error("invalid DXBC resinfo return format");
    if (r.dim == Dim::Buffer) {
        auto b = buffer(arg);
        Str x;
        if (mode == 2) x = b.size;
        else if (mode == 1) x = paren(b.size + " != 0u ? 1.0f / float(" + b.size + ") : 0.0f");
        else x = cast("float", b.size);
        Str result_value = mode == 2 ? "uint4(" + x + ", 0u, 0u, 0u)" :
                                       "float4(" + x + ", 0.0f, 0.0f, 0.0f)";
        assign(i, 0, swizzle(arg, result_value), mode == 2 ? 'u' : 'f');
        return;
    }
    auto d = shape(r.dim);
    Str tex = register_name(uav ? "u" : "t", arg.slot());
    bool mips = !d.ms && !uav && d.axes > 1;
    out.open("");
    if (!d.ms) out.line("uint dx_mip = " + scalar(i.args[1], 'b') + ";");
    Str mip = mips ? "dx_mip" : "";
    unsigned dims = d.cube ? 2 : d.axes;
    Str mip_count = mips ? tex + ".get_num_mip_levels()" : "1u";
    std::array<Str, 4> sizes{"0u", "0u", "0u", mip_count};
    constexpr View queries[] = {"get_width", "get_height", "get_depth"};
    for (unsigned j = 0; j < dims; ++j)
        sizes[j] = tex + "." + Str(queries[j]) + paren(mip);
    if (d.array) sizes[dims] = tex + ".get_array_size()";
    if (mode == 2) {
        if (mips) {
            for (unsigned j = 0; j < dims + unsigned(d.array); ++j)
                sizes[j] = paren("dx_mip < " + mip_count + " ? " + sizes[j] + " : 0u");
        } else if (!d.ms) {
            for (unsigned j = 0; j < dims + unsigned(d.array); ++j)
                sizes[j] = paren("dx_mip == 0u ? " + sizes[j] + " : 0u");
        }
    } else {
        for (unsigned j = 0; j < 4; ++j) {
            Str val = cast("float", sizes[j]);
            if (mode == 1 && j < dims) val = "1.0f / " + val;
            if (j < dims + unsigned(d.array)) {
                if (mips) val = paren("dx_mip < " + mip_count + " ? " + val + " : 0.0f");
                else if (!d.ms) val = paren("dx_mip == 0u ? " + val + " : 0.0f");
            }
            sizes[j] = val;
        }
    }
    assign(i, 0, swizzle(arg, call(mode == 2 ? "uint4" : "float4",
                                   {sizes[0], sizes[1], sizes[2], sizes[3]})),
           mode == 2 ? 'u' : 'f');
    out.close();
}

void Emitter::sample_position(const Instruction &i) {
    if (i.args.size() < 2) throw Error("missing DXBC samplepos resource operand");
    const auto &arg = i.args[1];
    if (arg.reg != Reg::Rasterizer || p.stage != 0)
        throw Error("DXBC texture samplepos requires the original texture sample pattern");
    i.count(3);
    Str sample = scalar(i.args[2]);
    Str position = paren(sample + " < get_num_samples() ? get_sample_position(" + sample +
                         ") - float2(0.5f) : float2(0.0f)");
    assign(i, 0, swizzle(arg, "float4(" + position + ", 0.0f, 0.0f)"), 'f');
}

bool Emitter::texture(const Instruction &i) {
    switch (i.op) {
    case Op::SAMPLE: case Op::SAMPLE_B: case Op::SAMPLE_D: case Op::SAMPLE_L:
    case Op::SAMPLE_C: case Op::SAMPLE_C_LZ: case Op::GATHER4: case Op::GATHER4_C:
    case Op::GATHER4_PO: case Op::GATHER4_PO_C: case Op::LOD:
        sample(i);
        break;
    case Op::LD: case Op::LD_MS: case Op::LD_UAV_TYPED:
        texture_read(i);
        break;
    case Op::STORE_UAV_TYPED: texture_write(i); break;
    case Op::RESINFO: case Op::SAMPLE_INFO: texture_info(i); break;
    case Op::SAMPLE_POS: sample_position(i); break;
    default: return false;
    }
    return true;
}

Buffer Emitter::buffer(const Operand &arg) const {
    uint32_t slot = arg.slot();
    bool uav = arg.reg == Reg::Uav;
    bool shared = arg.reg == Reg::Shared;
    if (!uav && !shared && arg.reg != Reg::Srv)
        throw Error("invalid DXBC buffer operand");
    const auto &r = resource_at(shared ? p.shared : uav ? p.uav : p.srv, slot);
    if (!r.buffer())
        throw Error("DXBC operand is not a buffer");
    Str pointer = register_name(shared ? "g" : uav ? "u" : "t", slot);
    if (shared)
        return {pointer, unsigned_literal(r.bytes / (r.stride ? r.stride : 4)), r.stride, r.type, r.dim, true, false};
    return {pointer, pointer + "_count", r.stride, r.type, r.dim, false, uav};
}

Str Emitter::byte_address(const Buffer &b, View element, View byte_offset) const {
    if (b.dim == Dim::Raw) return cast("ulong", byte_offset);
    if (b.dim == Dim::Structured)
        return "ulong(" + Str(element) + ") * " + unsigned_literal(b.stride) + " + " + Str(byte_offset);
    return "ulong(" + Str(element) + ") * " + b.pointer + "_stride";
}

void Emitter::buffer_op(const Instruction &i, bool load, bool structured) {
    i.count(structured ? 4 : 3);
    const auto &arg = i.args[load ? (structured ? 3 : 2) : 0];
    auto b = buffer(arg);
    if (b.dim != (structured ? Dim::Structured : Dim::Raw) || (!load && !b.shared && !b.uav))
        throw Error("DXBC buffer instruction and resource type mismatch");
    if (structured && !b.stride)
        throw Error("DXBC structured buffer stride is unavailable");
    out.open("");
    if (structured) out.line("uint dx_element = " + scalar(i.args[1]) + ";");
    out.line("uint dx_byte = " + scalar(i.args[structured ? 2 : 1]) + ";");
    out.line("ulong dx_address = " + byte_address(b, "dx_element", "dx_byte") + ";");
    if (load) out.line("uint4 dx_data = uint4(0u);");
    else out.line("uint4 dx_data = " + value(i.args.back()) + ";");
    Str limit = structured ? unsigned_literal(b.stride) :
                b.shared ? "ulong(" + b.size + ") * 4u" :
                           "ulong(" + b.size + ") * " + b.pointer + "_stride";
    Str check = "(dx_byte & 3u) == 0u";
    if (structured) check += " && dx_element < " + b.size;
    out.open("if " + paren(check));
    unsigned needed = 0;
    if (load) {
        for (unsigned lane = 0; lane < 4; ++lane) {
            if (i.args[0].mask & (1 << lane))
                needed |= 1 << arg.swizzle[lane];
        }
    } else {
        needed = arg.mask;
    }
    for (unsigned lane = 0; lane < 4; ++lane) {
        if (!(needed & (1 << lane))) continue;
        auto end = unsigned_literal(4 * (lane + 1));
        Str ptr = b.pointer + "[dx_address / 4u + " + unsigned_literal(lane) + "]";
        Str data = "dx_data." + Str(1, xyzw[lane]);
        out.open("if (ulong(dx_byte) + " + end + " <= " + limit + ")");
        out.line((load ? data + " = " + ptr : ptr + " = " + data) + ";");
        out.close();
    }
    out.close();
    if (load) assign(i, 0, swizzle(arg, "dx_data"));
    out.close();
}

void Emitter::atomic(const Instruction &i) {
    bool returns = i.op >= Op::IMM_ATOMIC_ALLOC;
    bool compare = i.op == Op::ATOMIC_CMP_STORE || i.op == Op::IMM_ATOMIC_CMP_EXCH;
    bool count = i.op == Op::IMM_ATOMIC_ALLOC || i.op == Op::IMM_ATOMIC_CONSUME;
    i.count(count ? 2 : 3 + returns + compare);
    const auto &arg = i.args[returns ? 1 : 0];
    if (arg.reg != Reg::Uav && arg.reg != Reg::Shared)
        throw Error("DXBC atomics require a UAV or threadgroup buffer");
    const auto &r = resource_at(arg.reg == Reg::Uav ? p.uav : p.shared, arg.slot());
    if (count) {
        if (arg.reg != Reg::Uav || r.dim != Dim::Structured)
            throw Error("DXBC counters require a structured UAV");
        uint8_t idx = result.bindings.uav_counter_idx[arg.slot()];
        if (idx == BO3_BIND_UNUSED)
            throw Error("missing binding for a DXBC UAV counter");
        Str counter = register_name("u", arg.slot()) + "_counter";
        bool alloc = i.op == Op::IMM_ATOMIC_ALLOC;
        Str expression = call(alloc ? "atomic_fetch_add_explicit" : "atomic_fetch_sub_explicit",
                              {counter, "1u", "memory_order_relaxed"});
        if (!alloc) expression = paren(expression + " - 1u");
        if (i.args[0].reg == Reg::Null) out.line("(void)" + expression + ";");
        else assign(i, 0, cast("uint4", expression));
        return;
    }
    bool signed_type = i.op == Op::ATOMIC_IMIN || i.op == Op::IMM_ATOMIC_IMIN ||
                       i.op == Op::ATOMIC_IMAX || i.op == Op::IMM_ATOMIC_IMAX;
    View fn;
    switch (i.op) {
    case Op::ATOMIC_AND: case Op::IMM_ATOMIC_AND: fn = "atomic_fetch_and"; break;
    case Op::ATOMIC_OR: case Op::IMM_ATOMIC_OR: fn = "atomic_fetch_or"; break;
    case Op::ATOMIC_XOR: case Op::IMM_ATOMIC_XOR: fn = "atomic_fetch_xor"; break;
    case Op::ATOMIC_IADD: case Op::IMM_ATOMIC_IADD: fn = "atomic_fetch_add"; break;
    case Op::ATOMIC_IMAX: case Op::IMM_ATOMIC_IMAX:
    case Op::ATOMIC_UMAX: case Op::IMM_ATOMIC_UMAX: fn = "atomic_fetch_max"; break;
    case Op::ATOMIC_IMIN: case Op::IMM_ATOMIC_IMIN:
    case Op::ATOMIC_UMIN: case Op::IMM_ATOMIC_UMIN: fn = "atomic_fetch_min"; break;
    case Op::IMM_ATOMIC_EXCH: fn = "atomic_exchange"; break;
    case Op::ATOMIC_CMP_STORE: case Op::IMM_ATOMIC_CMP_EXCH: break;
    default: throw Error("invalid DXBC atomic operation");
    }
    if (!r.buffer()) {
        texture_atomic(i, arg, r, fn, returns, compare, signed_type);
        return;
    }

    auto b = buffer(arg);
    Str pointer_type = Str(b.shared ? "threadgroup " : "device ") +
                       (signed_type ? "atomic_int *" : "atomic_uint *");
    Str ptr = "reinterpret_cast<" + pointer_type + ">(" + b.pointer + " + dx_address / 4u)";
    out.open("");
    out.line("uint4 dx_atomic_coord = " + value(i.args[returns ? 2 : 1]) + ";");
    Str element = "dx_atomic_coord.x";
    Str byte = b.dim == Dim::Structured ? "dx_atomic_coord.y" : element;
    out.line("ulong dx_address = " + byte_address(b, element, byte) + ";");
    if (returns) out.line("uint dx_original = 0u;");
    Str check;
    if (b.dim == Dim::Raw) {
        Str bytes = b.shared ? "ulong(" + b.size + ") * 4u" :
                               "ulong(" + b.size + ") * " + b.pointer + "_stride";
        check = "(dx_address & 3u) == 0u && dx_address + 4u <= " + bytes;
    } else if (b.dim == Dim::Structured) {
        check = element + " < " + b.size + " && (" + byte + " & 3u) == 0u && ulong(" + byte +
                ") + 4u <= " + unsigned_literal(b.stride);
    } else {
        check = element + " < " + b.size + " && " + b.pointer + "_stride == 4u";
    }
    out.open("if " + paren(check));
    Str data = scalar(i.args.back(), signed_type ? 'i' : 'u');
    Str exchange = compare ? call("dx_compare_exchange", {ptr, scalar(i.args[i.args.size() - 2]), data}) :
                             call(Str(fn) + "_explicit", {ptr, data, "memory_order_relaxed"});
    if (returns) {
        if (signed_type) exchange = bits("uint", exchange);
        out.line("dx_original = " + exchange + ";");
    } else {
        out.line(exchange + ";");
    }
    out.close();
    if (returns) assign(i, 0, "uint4(dx_original)");
    out.close();
}

void Emitter::texture_atomic(const Instruction &i, const Operand &uav, const Resource &r, View method,
                             bool returns, bool compare, bool signed_order) {
    auto d = shape(r.dim);
    if (d.ms || d.cube || (r.type != 3 && r.type != 4))
        throw Error("DXBC texture atomics require an R32 integer UAV");
    bool signed_texture = r.type == 3;
    bool minmax = method == "atomic_fetch_min" || method == "atomic_fetch_max";
    Str tex = register_name("u", uav.slot());
    View type = signed_texture ? "int4" : "uint4";
    char scalar_type = signed_texture ? 'i' : 'u';
    Str args = member("dx_atomic_coord", xyzw.substr(0, d.axes));
    if (d.array) args += ", dx_atomic_coord." + Str(1, xyzw[d.axes]);
    Str data = cast(type, scalar(i.args.back(), scalar_type));

    out.open("");
    out.line("uint4 dx_atomic_coord = " + value(i.args[returns ? 2 : 1]) + ";");
    if (returns) out.line("uint dx_original = 0u;");
    out.open("if " + paren(texel_bounds(tex, "dx_atomic_coord", d)));
    Str original;
    if (compare) {
        Str expected = scalar(i.args[i.args.size() - 2], scalar_type);
        out.line(Str(signed_texture ? "int" : "uint") + " dx_compare = " + expected + ";");
        out.line(Str(type) + " dx_expected = " + cast(type, "dx_compare") + ";");
        out.open("while (!" + tex + ".atomic_compare_exchange_weak(" + args +
                 ", &dx_expected, " + data + ") && dx_expected.x == dx_compare)");
        out.close();
        original = "dx_expected.x";
    } else if (minmax && signed_order != signed_texture) {
        // MSL orders min/max by the texture type. DXBC orders by the opcode.
        View order_type = signed_order ? "int" : "uint";
        Str operand = scalar(i.args.back(), signed_order ? 'i' : 'u');
        Str current = bits(order_type, "dx_expected.x");
        Str desired = call(method == "atomic_fetch_min" ? "min" : "max", {current, operand});
        out.line(Str(type) + " dx_expected = " + tex + ".atomic_load(" + args + ");");
        out.line("while (!" + tex + ".atomic_compare_exchange_weak(" + args + ", &dx_expected, " +
                 cast(type, bits(signed_texture ? "int" : "uint", desired)) + ")) {}");
        original = "dx_expected.x";
    } else {
        Str exchange = tex + "." + Str(method) + "(" + args + ", " + data + ")";
        if (returns) original = member(exchange, "x");
        else out.line(exchange + ";");
    }
    if (returns)
        out.line("dx_original = " + (signed_texture ? bits("uint", original) : original) + ";");
    out.close();
    if (returns) assign(i, 0, "uint4(dx_original)");
    out.close();
}

void Emitter::sync(const Instruction &i) {
    i.count(0);
    bool threads = i.token & 0x800;
    Str flags;
    if (i.token & 0x1000) flags = "mem_flags::mem_threadgroup";
    if (i.token & 0x6000) {
        if (!flags.empty()) flags += " | ";
        flags += "mem_flags::mem_device | mem_flags::mem_texture";
    }
    if (flags.empty()) flags = "mem_flags::mem_none";
    if (threads) {
        if (p.stage != 5) throw Error("DXBC group sync requires a compute shader");
        if (i.token & 0x4000)
            out.line("atomic_thread_fence(mem_flags::mem_device | mem_flags::mem_texture, memory_order_seq_cst);");
        out.line("threadgroup_barrier(" + flags + ");");
    } else if (i.token & 0x7000) {
        out.line("atomic_thread_fence(" + flags + ", memory_order_seq_cst);");
    }
}

bool Emitter::memory(const Instruction &i) {
    switch (i.op) {
    case Op::LD_STRUCTURED: buffer_op(i, true, true); break;
    case Op::STORE_STRUCTURED: buffer_op(i, false, true); break;
    case Op::LD_RAW: buffer_op(i, true, false); break;
    case Op::STORE_RAW: buffer_op(i, false, false); break;
    case Op::BUFINFO: {
        i.count(2);
        auto b = buffer(i.args[1]);
        Str size = b.dim == Dim::Raw ? b.size + " * " + (b.shared ? Str("4u") : b.pointer + "_stride") : b.size;
        assign(i, 0, cast("uint4", size));
        break;
    }
    case Op::ATOMIC_AND: case Op::ATOMIC_OR: case Op::ATOMIC_XOR: case Op::ATOMIC_CMP_STORE:
    case Op::ATOMIC_IADD: case Op::ATOMIC_IMAX: case Op::ATOMIC_IMIN: case Op::ATOMIC_UMAX: case Op::ATOMIC_UMIN:
    case Op::IMM_ATOMIC_ALLOC: case Op::IMM_ATOMIC_CONSUME: case Op::IMM_ATOMIC_IADD: case Op::IMM_ATOMIC_AND:
    case Op::IMM_ATOMIC_OR: case Op::IMM_ATOMIC_XOR: case Op::IMM_ATOMIC_EXCH: case Op::IMM_ATOMIC_CMP_EXCH:
    case Op::IMM_ATOMIC_IMAX: case Op::IMM_ATOMIC_IMIN: case Op::IMM_ATOMIC_UMAX: case Op::IMM_ATOMIC_UMIN:
        atomic(i);
        break;
    case Op::SYNC: sync(i); break;
    default: return false;
    }
    return true;
}

void Emitter::instruction(const Instruction &i) {
    if (!arithmetic(i) && !flow(i) && !texture(i) && !memory(i))
        throw Error("unsupported DXBC opcode");
}

constexpr View preamble = R"msl(#include <metal_stdlib>
using namespace metal;
#pragma METAL fp math_mode(safe)
#pragma METAL fp contract(off)

static inline float4 dx_saturate(float4 x) {
    return select(clamp(x, 0.0f, 1.0f), float4(0.0f), isnan(x));
}
static inline float4 dx_rcp(float4 x) { return 1.0f / x; }
static inline uint4 dx_iabs(uint4 x) {
    return select(x, -x, (x & uint4(0x80000000u)) != uint4(0u));
}
static inline uint4 dx_udiv(uint4 a, uint4 b) {
    return select(a / max(b, 1u), uint4(~0u), b == uint4(0u));
}
static inline uint4 dx_umod(uint4 a, uint4 b) {
    return select(a % max(b, 1u), uint4(~0u), b == uint4(0u));
}
static inline int4 dx_ftoi(float4 x) {
    x = select(x, float4(0.0f), isnan(x));
    int4 finite = int4(clamp(x, -2147483648.0f, 2147483520.0f));
    return select(finite, int4(2147483647), x >= 2147483648.0f);
}
static inline uint4 dx_ftou(float4 x) {
    x = select(x, float4(0.0f), isnan(x));
    uint4 finite = uint4(clamp(x, 0.0f, 4294967040.0f));
    return select(finite, uint4(~0u), x >= 4294967296.0f);
}
static inline uint4 dx_f32tof16(float4 x) {
    return uint4(as_type<ushort4>(half4(x)));
}
static inline float4 dx_f16tof32(uint4 x) {
    return float4(as_type<half4>(ushort4(x)));
}
static inline uint4 dx_first_hi(uint4 x) { return select(clz(x), uint4(~0u), x == uint4(0u)); }
static inline uint4 dx_first_lo(uint4 x) { return select(ctz(x), uint4(~0u), x == uint4(0u)); }
static inline uint4 dx_first_shi(uint4 x) {
    return dx_first_hi(select(x, ~x, (x & uint4(0x80000000u)) != uint4(0u)));
}
static inline uint4 dx_mad(uint4 a, uint4 b, uint4 c) { return a * b + c; }
static inline uint4 dx_bfi(uint4 width, uint4 offset, uint4 insert, uint4 base) {
    width &= 31u;
    offset &= 31u;
    uint4 mask = ((uint4(1u) << width) - 1u) << offset;
    return (base & ~mask) | ((insert << offset) & mask);
}
static inline uint4 dx_ubfe(uint4 width, uint4 offset, uint4 x) {
    width &= 31u;
    offset &= 31u;
    return (x >> offset) & ((uint4(1u) << width) - 1u);
}
static inline uint4 dx_ibfe(uint4 width, uint4 offset, uint4 x) {
    width &= 31u;
    offset &= 31u;
    uint4 right = 32u - min(width, 32u - offset);
    uint4 left = right - offset;
    uint4 result = as_type<uint4>(as_type<int4>(x << (left & 31u)) >> int4(right & 31u));
    return select(result, uint4(0u), width == uint4(0u));
}
)msl";

constexpr View atomic_helpers = R"msl(
static inline uint dx_compare_exchange(device atomic_uint *ptr, uint compare, uint value) {
    uint expected = compare;
    while (!atomic_compare_exchange_weak_explicit(ptr, &expected, value,
                  memory_order_relaxed, memory_order_relaxed) && expected == compare) {}
    return expected;
}
static inline uint dx_compare_exchange(threadgroup atomic_uint *ptr, uint compare, uint value) {
    uint expected = compare;
    while (!atomic_compare_exchange_weak_explicit(ptr, &expected, value,
                  memory_order_relaxed, memory_order_relaxed) && expected == compare) {}
    return expected;
}
)msl";

Str Emitter::emit() {
    build_io();
    out.source = preamble;
    if (std::any_of(p.instructions.begin(), p.instructions.end(), [](const Instruction &i) {
            return i.op == Op::ATOMIC_CMP_STORE || i.op == Op::IMM_ATOMIC_CMP_EXCH;
        })) out.source += atomic_helpers;
    if (!p.icb.empty()) {
        out.open("constant uint4 dx_icb_data[] =");
        for (size_t j = 0; j < p.icb.size(); j += 4) {
            out.line(call("uint4", {unsigned_literal(p.icb[j]), unsigned_literal(p.icb[j + 1]),
                                    unsigned_literal(p.icb[j + 2]), unsigned_literal(p.icb[j + 3])}) + ",");
        }
        out.close(";");
    }
    define_struct(p.stage == 1 ? "VSIn" : "PSIn", inputs);
    define_struct(p.stage == 1 ? "VSOut" : "PSOut", outputs);
    bind_parameters();
    Str entry = "[[host_name(\"" + result.entry_name + "\")]] ";
    if (p.stage == 0 && p.early_fragment_tests) entry += "[[early_fragment_tests]] ";
    entry += p.stage == 1 ? "vertex VSOut" : p.stage == 5 ? "kernel void" :
             outputs.empty() ? "fragment void" : "fragment PSOut";
    entry += " dx_entry(";
    for (size_t i = 0; i < params.size(); ++i) {
        if (i) entry += ", ";
        entry += params[i];
    }
    entry += ')';
    out.open(entry);
    initialize_registers();
    auto emit_buffer_info = [&](const auto &resources, bool uav) {
        for (const auto &[slot, r] : resources) {
            if (!r.buffer()) continue;
            uint32_t metal = (uav ? result.bindings.uav[slot] : result.bindings.srv[slot]) & BO3_BIND_IDX_MASK;
            Str ptr = register_name(uav ? "u" : "t", slot);
            out.line("const uint " + ptr + "_count = bufferInfo[" + decimal(metal * 2) + "];");
            Str stride = r.dim == Dim::Structured && r.stride ? unsigned_literal(r.stride) :
                         "bufferInfo[" + decimal(metal * 2 + 1) + "]";
            out.line("const uint " + ptr + "_stride = " + stride + ";");
        }
    };
    emit_buffer_info(p.srv, false);
    emit_buffer_info(p.uav, true);
    for (const auto &i : p.instructions) {
        try {
            instruction(i);
        } catch (const Error &e) {
            throw Error("DXBC opcode " + decimal(unsigned(i.op)) + " at word " + decimal(i.word) + ": " + e.what());
        }
    }
    if (!scopes.empty()) throw Error("unterminated DXBC control-flow block");
    if (p.instructions.empty() || p.instructions.back().op != Op::RET) emit_return();
    out.close();
    return std::move(out.source);
}

} // namespace
} // namespace bo3::dxbc

DxbcTranslateResult bo3_translate_dxbc_to_msl(
    const uint8_t *dxbc, size_t len, const char *entry_name, const char *shader_debug_name) {
    return bo3_translate_dxbc_to_msl(dxbc, len, entry_name, shader_debug_name, bo3::dxbc::Options{});
}

DxbcTranslateResult bo3_translate_dxbc_to_msl(
    const uint8_t *dxbc, size_t len, const char *entry_name, const char *shader_debug_name,
    const bo3::dxbc::Options &options) {
    using namespace bo3::dxbc;
    DxbcTranslateResult result{};
    bo3_binding_map_init(&result.bindings);
    try {
        if (!dxbc) throw Error("DXBC pointer is null");
        Container container(Bytes(dxbc, len));
        if (container.code.size() >= 4) result.stage = container.code[2];
        result.inputs = signature(container.input, container.input_kind);
        result.outputs = signature(container.output, container.output_kind);
        Program program(container);
        result.stage = program.stage;
        result.entry_name = entry_name && *entry_name ? entry_name : "bo3_main";
        if (!identifier(result.entry_name)) throw Error("invalid Metal entry name " + result.entry_name);
        program.allocate(result.bindings);
        result.msl = Emitter(program, result, options).emit();
        result.ok = true;
    } catch (const Error &e) {
        if (shader_debug_name && *shader_debug_name)
            result.error = Str(shader_debug_name) + ": ";
        result.error += e.what();
        bo3_binding_map_init(&result.bindings);
    }
    return result;
}

bool bo3_parse_dxbc_input_signature(
    const uint8_t *dxbc, size_t len, std::vector<DxbcSigElem> *out_inputs) {
    using namespace bo3::dxbc;
    if (!out_inputs) return false;
    out_inputs->clear();
    if (!dxbc) return false;
    try {
        Container container(Bytes(dxbc, len));
        if (!container.input_kind) return false;
        *out_inputs = signature(container.input, container.input_kind);
        return true;
    } catch (const Error &) {
        return false;
    }
}
