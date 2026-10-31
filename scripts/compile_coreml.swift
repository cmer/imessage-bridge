// Compiles a Core ML package to .mlmodelc without Xcode's coremlcompiler.
//   swift scripts/compile_coreml.swift In.mlpackage Out.mlmodelc
import CoreML
import Foundation

let args = CommandLine.arguments
guard args.count == 3 else {
    FileHandle.standardError.write(Data("usage: compile_coreml.swift <in.mlpackage> <out.mlmodelc>\n".utf8))
    exit(2)
}
let compiled = try MLModel.compileModel(at: URL(fileURLWithPath: args[1]))
let dest = URL(fileURLWithPath: args[2])
try? FileManager.default.removeItem(at: dest)
try FileManager.default.moveItem(at: compiled, to: dest)
