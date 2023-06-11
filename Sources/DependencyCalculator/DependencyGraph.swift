//
//  Created by Mike Gerasymenko <mike@gera.cx>
//

import Foundation
import XcodeProj
import PathKit
import Workspace
import Logger
import Git

extension PBXBuildFile {
    func path(projectFolder: Path) -> Path? {
        
        if let path = self.file?.path {
            if let parent = self.file?.parent?.path {
                return projectFolder + parent + path
            }
            else {
                return projectFolder + path
            }
        }
        else {
            Logger.warning("File without path: \(self)")
            return nil
        }
    }
}

extension WorkspaceInfo {
    public static func parseWorkspace(at path: Path,
                                      config: WorkspaceInfo.AdditionalConfig? = nil) throws -> WorkspaceInfo {
        guard path.extension == "xcworkspace" else {
            return try WorkspaceInfo.parseProject(at: path)
        }
        
        let workspace = try XCWorkspace(path: path)
        
        let workspaceDefinitionPath = path + "contents.xcworkspacedata"
        
        let (packageWorkspaceInfo, packages) = try parsePackages(in: path)
        
        var resultDependencies = packageWorkspaceInfo.dependencyStructure
        var files = packageWorkspaceInfo.files
        var folders = packageWorkspaceInfo.folders
        
        let allProjects = try workspace.allProjects(basePath: path.parent())
        
        try allProjects.forEach { (project, projectPath) in
            let newDependencies = try parseProject(from: project,
                                                   path: projectPath,
                                                   packages: packages,
                                                   allProjects: allProjects)
            resultDependencies = resultDependencies.merging(with: newDependencies.dependencyStructure)
            
            let projectDefinitionPath = projectPath + "project.pbxproj"
            
            var newFiles = [TargetIdentity: Set<Path>]()
            
            // Append project and workspace paths, as they might change the project compilation
            newDependencies.files.forEach { (target, files) in
                newFiles[target] = files.union([workspaceDefinitionPath, projectDefinitionPath])
            }
            
            files = files.merging(with: newFiles)
            folders = folders.merging(with: newDependencies.folders)
        }
        
        let workspaceInfo = WorkspaceInfo(files: files,
                                          folders: folders,
                                          dependencyStructure: resultDependencies)
        if let config {
            // Process additional config
            return processAdditional(config: config, workspaceInfo: workspaceInfo)
        }
        else {
            return workspaceInfo
        }
    }
    
    static func processAdditional(config: WorkspaceInfo.AdditionalConfig,
                                  workspaceInfo: WorkspaceInfo) -> WorkspaceInfo {
        
        var files = workspaceInfo.files
        var folders = workspaceInfo.folders
        var resultDependencies = workspaceInfo.dependencyStructure
        
        config.dependencies.forEach { targetName, dependOnTargets in
            guard let target = resultDependencies.findTarget(shortOrFullName: targetName) else {
                Logger.error("Config: Cannot resolve \(targetName) to any known target")
                return
            }
            dependOnTargets.forEach { dependOnTargetName in
                guard let targetDependOn = resultDependencies.findTarget(shortOrFullName: dependOnTargetName) else {
                    Logger.error("Config: Cannot resolve \(dependOnTargetName) to any known target")
                    return
                }
                
                let newDependency = DependencyGraph(dependsOn: [target: Set([targetDependOn])])
                
                resultDependencies = resultDependencies.merging(with: newDependency)
            }
        }
        
        config.targetsFiles.forEach { (targetName: String, filesToAdd: [String]) in

            guard let target = resultDependencies.findTarget(shortOrFullName: targetName) else {
                Logger.error("Config: Cannot resolve \(targetName) to any known target")
                return
            }

            filesToAdd.forEach { filePath in
                let path = Path(filePath).absolute()

                guard path.exists else {
                    Logger.error("Config: Path \(path) does not exist")
                    return
                }

                if path.isDirectory {
                    folders[path] = target
                }
                else {
                    var filesForTarget = files[target] ?? Set<Path>()
                    filesForTarget.insert(path)
                    files[target] = filesForTarget
                }
            }
        }
        
        return WorkspaceInfo(files: files,
                             folders: folders,
                             dependencyStructure: resultDependencies)
    }
    
    static func findPackages(in path: Path) throws -> [String: PackageMetadata] {
        return try Array(Git(path: path).find(pattern: "/Package.swift")).concurrentMap { path in
            return try? PackageMetadata.parse(at: path.parent())
        }.compactMap { $0 }.reduce([String: PackageMetadata](), { partialResult, new in
            var result = partialResult
            result[new.name] = new
            return result
        })
    }
    
    static func parsePackages(in path: Path) throws -> (WorkspaceInfo, [String: PackageMetadata]) {
        
        var dependsOn: [TargetIdentity: Set<TargetIdentity>] = [:]
        var folders: [Path: TargetIdentity] = [:]
        
        let packages = try findPackages(in: path)
        
        packages.forEach { (name, metadata) in
            metadata.dependsOn.forEach { dependency in
                dependsOn.insert(metadata.targetIdentity(), dependOn: dependency)
            }
            
            folders[metadata.path] = metadata.targetIdentity()
        }
        
        return (WorkspaceInfo(files: [:],
                              folders: folders,
                              dependencyStructure: DependencyGraph(dependsOn: dependsOn)), packages)
    }
    
    static func parseProject(from project: XcodeProj,
                             path: Path,
                             packages: [String: PackageMetadata],
                             allProjects: [(XcodeProj, Path)]) throws -> WorkspaceInfo {
        
        var dependsOn: [TargetIdentity: Set<TargetIdentity>] = [:]
        var files: [TargetIdentity: Set<Path>] = [:]
        var folders: [Path: TargetIdentity] = [:]
        
        try project.pbxproj.nativeTargets.forEach { target in
            let targetIdentity = TargetIdentity(projectPath: path, target: target)
            // Target dependencies
            target.dependencies.forEach { dependency in
                guard let name = dependency.target?.name else {
                    Logger.warning("Target without name: \(dependency)")
                    return
                }
                dependsOn.insert(targetIdentity,
                                dependOn: TargetIdentity(projectPath: path, targetName: name))
            }
            
            // Package dependencies
            target.packageProductDependencies.forEach { packageDependency in
                let package = packageDependency.productName
                guard let packageMetadata = packages[package] else {
                    Logger.warning("Package \(package) not found")
                    return
                }
                dependsOn.insert(targetIdentity,
                                 dependOn: TargetIdentity.swiftPackage(path: packageMetadata.path, name: package))
            }
            
            // Source Files
            var filesPaths = Set(try target.sourcesBuildPhase()?.files?.compactMap { file in
                return file.path(projectFolder: path.parent())
            } ?? [])
            
            // Resources
            filesPaths = filesPaths.union(Set(try target.resourcesBuildPhase()?.files?.compactMap { file in
                return file.path(projectFolder: path.parent())
            } ?? []))
            
            try target.frameworksBuildPhase()?.files?.forEach { file in
                allProjects.forEach { (proj, projPath) in
                    proj.pbxproj.nativeTargets.forEach { someTarget in
                        if someTarget.productNameWithExtension() == file.file?.path {
                            dependsOn.insert(targetIdentity,
                                             dependOn: TargetIdentity(projectPath: projPath, targetName: someTarget.name))
                        }
                    }
                }
            }
                        
            filesPaths.forEach { path in
                if path.isDirectory {
                    folders[path] = targetIdentity
                }
            }
            files[targetIdentity] = filesPaths
        }
        
        return WorkspaceInfo(files: files, folders: folders, dependencyStructure: DependencyGraph(dependsOn: dependsOn))
    }
    
    public static func parseProject(at path: Path) throws -> WorkspaceInfo {
        
        let (packageWorkspaceInfo, packages) = try parsePackages(in: path)
        
        let xcodeproj = try XcodeProj(path: path)
        
        let projectInfo = try parseProject(from: xcodeproj, path: path, packages: packages, allProjects: [])
        
        return WorkspaceInfo(files: projectInfo.files.merging(with: packageWorkspaceInfo.files),
                             folders: projectInfo.folders.merging(with: packageWorkspaceInfo.folders),
                             dependencyStructure: projectInfo.dependencyStructure.merging(with: packageWorkspaceInfo.dependencyStructure))
    }
}
