import { ToolContract } from '../agent/ToolContract';
import { fileContract } from '../agent/contracts/FileContracts';
import fs from '@ohos.file.fs';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { common } from '@kit.AbilityKit';
import { AgentTool } from '../agent/AgentTool';
import {
  normalizeWorkspaceRelativePath,
  sandboxWorkspacePath
} from './SandboxWorkspace';
import { ensureBundledWorkspaceFiles } from './SandboxWorkspaceStore';

const LOG_DOMAIN = 0x0000;
const LOG_TAG = 'SandboxFile';
const MAX_CONTENT_BYTES = 100 * 1024;

interface SandboxFileWriteRequest {
  relativePath?: string;
  content?: string;
}

export class SandboxFileWriteTool implements AgentTool {
  contract(): ToolContract { return fileContract(this.name(), 'write'); }

  private context: common.UIAbilityContext;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  name(): string {
    return 'write_sandbox_file';
  }

  description(): string {
    return 'Writes text content to a file in the workspace. Use only when the user explicitly asks to save, write or create a file; ' +
      'when the user only wants to read the text (a story, summary, draft), answer with Final instead. All paths are relative to the workspace root. ' +
      'Input JSON: {"relativePath":"folder/file.txt","content":"text"}. ' +
      'Absolute paths and .. are rejected.';
  }

  async run(input: string): Promise<string> {
    try {
      await ensureBundledWorkspaceFiles(this.context);
      const request = JSON.parse(input.trim()) as SandboxFileWriteRequest;
      const relativePath = this.validateRelativePath(`${request.relativePath ?? ''}`);
      const content = `${request.content ?? ''}`;
      if (content.length === 0) {
        throw new Error('Missing content.');
      }
      if (content.length > MAX_CONTENT_BYTES) {
        throw new Error(`Content too large. Limit is ${MAX_CONTENT_BYTES} characters.`);
      }

      const targetPath = sandboxWorkspacePath(relativePath);
      this.ensureParentDirectory(targetPath);
      this.writeTextFile(targetPath, content);
      this.logInfo(`wrote relativePath=${relativePath}`);
      return `Wrote sandbox file: ${relativePath}`;
    } catch (error) {
      const message = error instanceof Error ? error.message : `${error}`;
      this.logWarn(`write failed; ${message}`);
      return `Failed to write sandbox file: ${message}`;
    }
  }

  private validateRelativePath(path: string): string {
    return normalizeWorkspaceRelativePath(path, false);
  }

  private ensureParentDirectory(path: string): void {
    const slash = path.lastIndexOf('/');
    if (slash <= 0) {
      return;
    }
    const parent = path.substring(0, slash);
    this.ensureDirectory(parent);
  }

  private ensureDirectory(path: string): void {
    if (this.pathExists(path)) {
      return;
    }
    fs.mkdirSync(path, true);
  }

  private pathExists(path: string): boolean {
    try {
      return fs.accessSync(path);
    } catch (_error) {
      return false;
    }
  }

  private writeTextFile(path: string, text: string): void {
    const file = fs.openSync(path, fs.OpenMode.READ_WRITE | fs.OpenMode.CREATE | fs.OpenMode.TRUNC);
    try {
      fs.writeSync(file.fd, text);
    } finally {
      fs.closeSync(file);
    }
  }

  private logInfo(message: string): void {
    hilog.info(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }

  private logWarn(message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, '%{public}s', message);
  }
}
