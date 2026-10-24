// Build-time check for the mesa_clc host libraries (nextbsd-toolchain#11).
//
// Compiles one OpenCL C kernel to SPIR-V the way Mesa 26.2's mesa_clc does on
// LLVM 19 (src/compiler/clc/clc_helpers.cpp): clang's C++ API (libclang-cpp)
// with clang's own resource headers -> LLVM IR (libLLVM) -> SPIR-V
// (LLVMSPIRVLib) -> SPIRV-Tools linker with SetAllowPtrTypeMismatch, then
// disassembles the result. Exits non-zero if any step fails.
#include <clang/Basic/DiagnosticIDs.h>
#include <clang/Basic/DiagnosticOptions.h>
#include <clang/Basic/TargetInfo.h>
#include <clang/CodeGen/CodeGenAction.h>
#include <clang/Frontend/CompilerInstance.h>
#include <clang/Frontend/CompilerInvocation.h>
#include <clang/Frontend/TextDiagnosticPrinter.h>
#include <clang/Lex/PreprocessorOptions.h>
#include <llvm/IR/LLVMContext.h>
#include <llvm/IR/Module.h>
#include <llvm/Support/MemoryBuffer.h>
#include <llvm/Support/raw_ostream.h>
#include <LLVMSPIRVLib/LLVMSPIRVLib.h>
#include <spirv-tools/libspirv.hpp>
#include <spirv-tools/linker.hpp>

#include <cstdint>
#include <cstdio>
#include <cstring>
#include <memory>
#include <sstream>
#include <string>
#include <vector>

#ifndef RESOURCE_DIR
#error "define RESOURCE_DIR as the clang resource directory"
#endif

static int fail(const char *what, const std::string &detail = "")
{
    std::fprintf(stderr, "check-clc: %s%s%s\n", what,
                 detail.empty() ? "" : ": ", detail.c_str());
    return 1;
}

int main()
{
    static const char source[] =
        "kernel void fill(global uint *out, uint v)\n"
        "{\n"
        "    size_t i = get_global_id(0);\n"
        "    out[i] = popcount(v) + clz(v) + (uint)i;\n"
        "}\n";

    llvm::IntrusiveRefCntPtr<clang::DiagnosticOptions> diag_opts =
        new clang::DiagnosticOptions;
    clang::DiagnosticsEngine diag(
        new clang::DiagnosticIDs, diag_opts,
        new clang::TextDiagnosticPrinter(llvm::errs(), diag_opts.get()));

    // The cc1 arguments mesa_clc passes on LLVM >= 17, plus the resource
    // directory, so opencl-c-base.h comes from the installed clang headers.
    const std::vector<const char *> args = {
        "input.cl",
        "-triple", "spirv64-unknown-unknown",
        "-fdeclare-opencl-builtins",
        "-finclude-default-header",
        "-cl-std=cl1.2",
        "-fno-builtin-memset",
        "-O0",
        "-fgnu89-inline",
        "-resource-dir", RESOURCE_DIR,
    };

    auto ci = std::make_unique<clang::CompilerInstance>();
    if (!clang::CompilerInvocation::CreateFromArgs(ci->getInvocation(), args, diag) ||
        diag.hasErrorOccurred())
        return fail("could not create the clang invocation");

    ci->createDiagnostics();
    ci->setTarget(clang::TargetInfo::CreateTargetInfo(
        ci->getDiagnostics(), ci->getInvocation().TargetOpts));
    ci->getPreprocessorOpts().addRemappedFile(
        "input.cl", llvm::MemoryBuffer::getMemBufferCopy(source).release());

    llvm::LLVMContext ctx;
    clang::EmitLLVMOnlyAction act(&ctx);
    if (!ci->ExecuteAction(act))
        return fail("clang could not compile the OpenCL C kernel");
    std::unique_ptr<llvm::Module> mod = act.takeModule();
    if (!mod)
        return fail("clang produced no module");

    SPIRV::TranslatorOpts spirv_opts(SPIRV::VersionNumber::SPIRV_1_0,
                                     SPIRV::TranslatorOpts::ExtensionsStatusMap());
    spirv_opts.setPreserveOCLKernelArgTypeMetadataThroughString(true);
    std::ostringstream spv_stream;
    std::string log;
    if (!llvm::writeSpirv(mod.get(), spirv_opts, spv_stream, log))
        return fail("SPIRV-LLVM-Translator failed", log);

    const std::string spv = spv_stream.str();
    if (spv.size() < 20 || spv.size() % 4 != 0)
        return fail("translator output is not a SPIR-V module");
    std::vector<uint32_t> words(spv.size() / 4);
    std::memcpy(words.data(), spv.data(), spv.size());
    if (words[0] != 0x07230203u)
        return fail("bad SPIR-V magic number");

    spvtools::Context context(SPV_ENV_UNIVERSAL_1_0);
    spvtools::LinkerOptions link_opts;
    link_opts.SetAllowPartialLinkage(true);
    link_opts.SetUseHighestVersion(true);
    link_opts.SetAllowPtrTypeMismatch(true);
    link_opts.SetCreateLibrary(true);
    const std::vector<std::vector<uint32_t>> binaries = {words};
    std::vector<uint32_t> linked;
    if (spvtools::Link(context, binaries, &linked, link_opts) != SPV_SUCCESS)
        return fail("SPIRV-Tools could not link the module");

    spvtools::SpirvTools tools(SPV_ENV_UNIVERSAL_1_0);
    std::string text;
    if (!tools.Disassemble(linked, &text) ||
        text.find("OpEntryPoint Kernel") == std::string::npos ||
        text.find("\"fill\"") == std::string::npos)
        return fail("linked module has no `fill` kernel entry point");

    std::printf("check-clc: OpenCL C -> SPIR-V OK (%zu bytes translated, %zu linked)\n",
                spv.size(), linked.size() * 4);
    return 0;
}
