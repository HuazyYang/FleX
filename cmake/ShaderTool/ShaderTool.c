#include <Windows.h>
#include <string.h>
#include <stdio.h>
#include <stdarg.h>
// #include <vld.h>

BOOL APIENTRY MyCreatePipeEx(OUT LPHANDLE lpReadPipe, OUT LPHANDLE lpWritePipe,
                             IN LPSECURITY_ATTRIBUTES lpPipeAttributes, IN DWORD nSize,
                             DWORD dwReadMode, DWORD dwWriteMode);

typedef struct AStringView {
    LPCSTR Buffer;
    UINT Length;
} AStringView;

#define ASTRING_VIEW_INITIALIZER2(sz, length) {(sz) ? (sz) : "", (length)}

typedef struct AString {
    UINT Length;
    UINT MaxLength;
    LPSTR Buffer;
} AString;

typedef struct Args {
    AStringView FxcProg;
    AString FxcOptionsBuffer;
    AStringView *FxcOptions;
    UINT NumFxcOptions;
    AStringView DepFilePath;
    AStringView SourceFilePath;
    AStringView OutputFilePath;
} Args;

typedef struct ByteBuffer {
    union {
        LPVOID Buffer;
        LPSTR AStrBuffer;
        LPWSTR WStrBuffer;
    };
    UINT Size;
    UINT Capacity;
} ByteBuffer;

typedef struct DependsParserContext {
    BOOL Enabled;
    UINT SessionState;
    UINT LineIndex;
    ByteBuffer SrcContent;
    AString Target;
    ByteBuffer DependList;
} DependsParserContext;

LPVOID MyHeapReAlloc(LPVOID pv, SIZE_T numBytes) {
    if (!pv)
        return HeapAlloc(GetProcessHeap(), 0, numBytes);
    else
        return HeapReAlloc(GetProcessHeap(), 0, pv, numBytes);
}

#pragma region[ AStringView ]

AStringView AStringViewCreate(LPCSTR sz) {
    AStringView s;
    if (sz) {
        s.Buffer = sz;
        s.Length = strlen(sz);
    } else {
        s.Buffer = "";
        s.Length = 0;
    }
    return s;
}

void AStringViewInit(AStringView *s, LPCSTR psz) {
    if (psz) {
        s->Buffer = psz;
        s->Length = strlen(psz);
    } else {
        s->Buffer = "";
        s->Length = 0;
    }
}

void AStringViewInit2(AStringView *s, LPCSTR psz, UINT length) {
    s->Buffer = psz ? psz : "";
    s->Length = length;
}

BOOL AStringViewIsEmpty(const AStringView *s) {
    return !s->Buffer || s->Length == 0;
}

BOOL AStringViewEqual(const AStringView *s, LPCSTR sz) {
    UINT len;
    if (sz == NULL)
        sz = "";

    len = strlen(sz);
    return len == s->Length && strncmp(s->Buffer, sz, s->Length) == 0;
}

BOOL AStringViewEqual2(const AStringView *s, const AStringView *s2) {
    return s->Length == s2->Length && strncmp(s->Buffer, s2->Buffer, s->Length) == 0;
}

BOOL AStringViewEqualAtLeast(const AStringView *s, const AStringView *s2) {
    return s->Length >= s2->Length && strncmp(s->Buffer, s2->Buffer, s2->Length) == 0;
}

#pragma endregion[AStringView]

#pragma region[ AString ]

void AStringDeinit(AString *s) {
    if (s->Buffer) {
        HeapFree(GetProcessHeap(), 0, s->Buffer);
        s->Buffer = NULL;
    }
    s->Length = 0;
    s->MaxLength = 0;
}

int AStringResize(AString *s, UINT length) {
    UINT newCapacity;
    LPSTR newBuffer;
    if (s->MaxLength < length) {
        newCapacity = ((length + 1) * 2 + 0x7F) & ~0x7F;
        newBuffer = (LPSTR)MyHeapReAlloc(s->Buffer, newCapacity * sizeof(WCHAR));
        if (!newBuffer) {
            fprintf(stderr, "Failed to allocate enough memory for AString\n");
            return -1;
        }
        s->Buffer = newBuffer;
        s->MaxLength = newCapacity - 1;
    }

    if (s->Buffer)
        s->Buffer[length] = 0;
    s->Length = length;

    return 0;
}

int AStringCatN(AString *s, UINT numSrcViews, ...) {
    UINT len = s->Length, prevLen;
    UINT buffCapacity;
    LPCSTR newBuffer;
    va_list ap;
    const AStringView *currSrc;
    UINT i;

    prevLen = len;

    va_start(ap, numSrcViews);
    for (i = 0; i < numSrcViews; ++i) {
        currSrc = va_arg(ap, const AStringView *);
        len += currSrc->Length;
    }
    va_end(ap);

    if (AStringResize(s, len))
        return -1;

    va_start(ap, numSrcViews);
    for (i = 0; i < numSrcViews; ++i) {
        currSrc = va_arg(ap, const AStringView *);
        strncpy(s->Buffer + prevLen, currSrc->Buffer, currSrc->Length);
        prevLen += currSrc->Length;
    }
    va_end(ap);

    s->Buffer[s->Length] = 0;

    return 0;
}

int AStringCopy(AString *s, const AStringView *src) {
    s->Length = 0;
    return AStringCatN(s, 1, src);
}

#pragma endregion[AString]

#pragma region[ ByteBuffer ]

int ByteBufferResize(ByteBuffer *buffer, UINT size) {
    LPVOID newBuffer;
    UINT newCapacity;
    if (size > buffer->Size) {
        newCapacity = (2 * size + 0x3FFu) & ~0x3FFu;
        newBuffer = MyHeapReAlloc(buffer->Buffer, newCapacity);
        if (!newBuffer) {
            fprintf(stderr, "Failed to allocate enough memory for ByteBuffer\n");
            return -1;
        }

        buffer->Capacity = newCapacity;
        buffer->Buffer = newBuffer;
    }
    buffer->Size = size;
    return 0;
}

void ByteBufferGetAStringView(const ByteBuffer *buffer, AStringView *s) {
    s->Buffer = buffer->AStrBuffer;
    s->Length = buffer->Size;
}

int ByteBufferWrite(ByteBuffer *buffer, LPCVOID data, UINT size) {
    UINT totalSize;
    UINT prevSize;

    if (!size)
        return 0;

    totalSize = buffer->Size + size;
    prevSize = buffer->Size;

    if (ByteBufferResize(buffer, totalSize))
        return -1;

    memcpy((UINT8 *)buffer->Buffer + prevSize, data, size);
    return 0;
}

int ByteBufferCatAStringViews(ByteBuffer *buffer, UINT n, ...) {
    UINT totalSize;
    UINT prevSize;
    va_list ap;
    UINT i;
    const AStringView *curr;
    int ret = -1;

    totalSize = buffer->Size;
    prevSize = totalSize;

    va_start(ap, n);
    for (i = 0; i < n; ++i) {
        curr = va_arg(ap, const AStringView *);
        totalSize += curr->Length;
    }
    va_end(ap);

    if (ByteBufferResize(buffer, totalSize))
        return -1;

    va_start(ap, n);
    for (int i = 0; i < n; ++i) {
        curr = va_arg(ap, const AStringView *);
        memcpy((UINT8 *)buffer->Buffer + prevSize, curr->Buffer, curr->Length);
        prevSize += curr->Length;
    }
    va_end(ap);

    return 0;
}

void ByteBufferDeinit(ByteBuffer *buffer) {
    if (buffer->Buffer) {
        HeapFree(GetProcessHeap(), 0, buffer->Buffer);
        buffer->Buffer = NULL;
    }
    buffer->Size = 0;
    buffer->Capacity = 0;
}

int ByteBufferEraseRange(ByteBuffer *buffer, UINT start, UINT end) {
    UINT8 *rangeStart, *rangeMid, *rangeEnd;

    if (start > end || end > buffer->Size) {
        fprintf(stdout, "Erase byte buffer range out of range\n");
        return -1;
    }

    UINT rightLen = buffer->Size - end;
    if (start < end)
        memmove((UINT8 *)buffer->Buffer + start, (UINT8 *)buffer->Buffer + end, rightLen);

    buffer->Size = start + rightLen;
    return 0;
}

#pragma endregion[ByteBuffer]

#pragma region[ Args ]

void ArgsDeinit(Args *args) {
    if (args->FxcOptions) {
        HeapFree(GetProcessHeap(), 0, args->FxcOptions);
        args->FxcOptions = NULL;
    }
    AStringDeinit(&args->FxcOptionsBuffer);
    ZeroMemory(args, sizeof(*args));
}

int ArgsParseFxcCommandLine(Args *args, const AStringView *fxcCmdLine) {
    LPSTR p1, p2, p3;
    UINT numOptions = args->NumFxcOptions;
    UINT numCapacity = numOptions;
    AStringView *newBuffer;
    AStringView newOption, newValue;
    BOOL requireVerifyValue = FALSE;

    if (AStringCatN(&args->FxcOptionsBuffer, 1, fxcCmdLine))
        return -1;

    p1 = args->FxcOptionsBuffer.Buffer;
    p3 = p1 + args->FxcOptionsBuffer.Length;

    for (; p1 != p3;) {
        for (; p1 != p3 && (*p1 == ' ' || *p1 == ',' || *p1 == ';'); ++p1)
            ;
        for (p2 = p1; p2 != p3 && (*p2 != ' ' && *p2 != ';' && *p2 != ','); ++p2)
            ;
        if (p1 != p2) {
            requireVerifyValue = FALSE;

            // Rewrite option prefix as FXC convention '/'
            if (*p1 == '-' && p2 - p1 >= 2)
                *p1 = '/';

            AStringViewInit2(&newOption, p1, p2 - p1);
            AStringViewInit(&newValue, NULL);

            if (AStringViewEqual(&newOption, "/Fo") ||
                AStringViewEqual(&newOption, "/Fh")) {
                if (newOption.Length > 3) {
                    AStringViewInit2(&newValue, newOption.Buffer + 3, newOption.Length - 3);
                    newOption.Length = 3;
                } else
                    requireVerifyValue = TRUE;
            }

            if (AStringViewEqual(&newOption, "/D") || AStringViewEqual(&newOption, "/I")) {
                if (newOption.Length > 2) {
                    AStringViewInit2(&newValue, newOption.Buffer + 2, newOption.Length - 2);
                    newOption.Length = 2;
                } else
                    requireVerifyValue = TRUE;
            }

            numOptions += 1 + !AStringViewIsEmpty(&newValue);
            if (numOptions > numCapacity) {
                numCapacity = numOptions * 2;
                newBuffer =
                    MyHeapReAlloc(args->FxcOptions, numCapacity * sizeof(AStringView));
                if (!newBuffer) {
                    fprintf(stderr, "Failed to allocate enough memory for FxcOptions\n");
                    return -1;
                }
                args->FxcOptions = newBuffer;
            }

            args->FxcOptions[args->NumFxcOptions++] = newOption;
            if (!AStringViewIsEmpty(&newValue))
                args->FxcOptions[args->NumFxcOptions++] = newValue;
        }
        p1 = p2;
    }

    if (requireVerifyValue) {
        fprintf(stderr, "FXC options /Fo, /Fh, /D, /I need a value, but none provided\n");
        return -1;
    }

    return 0;
}

BOOL ArgsHasDepfile(const Args *args) {
    return !AStringViewIsEmpty(&args->DepFilePath);
}

#pragma endregion[Args]

LPCSTR ReadNextLine(LPCSTR start, LPCSTR end) {
    for (; start != end && *start != '\n'; ++start)
        ;
    if (start != end)
        ++start;
    return start;
}

int NormalizeAPath(const AStringView *s, AString *result) {
    const AStringView sep = ASTRING_VIEW_INITIALIZER2("/", 1);
    const AStringView dots2 = ASTRING_VIEW_INITIALIZER2("..", 2);
    const AStringView dots1 = ASTRING_VIEW_INITIALIZER2(".", 1);
    LPCSTR start = s->Buffer, next, end = s->Buffer + s->Length;
    AStringView pathPart;
    UINT nameLen;
    LPCSTR resStart, resEnd, resNext;

    // TODO: resolve relative path to absolute path for .. to work properly

    if (AStringResize(result, 0))
        return -1;

    for (; start != end;) {
        if (*start == '\\' || *start == '/') {
            if (AStringCatN(result, 1, &sep))
                return -1;
            ++start;
            if (start == end)
                break;
        }

        for (; start != end && (*start == '\\' || *start == '/'); ++start)
            ;
        if (start == end)
            break;

        for (next = start + 1; next != end && (*next != '\\' && *next != '/'); ++next)
            ;

        AStringViewInit2(&pathPart, start, next - start);

        if (AStringViewEqual2(&pathPart, &dots2)) {
            resStart = result->Length ? result->Buffer + result->Length - 1 : NULL;
            resEnd = resStart - result->Length;  // assume sizeof(CHAR) is 1
            if (resStart == resEnd || *resStart != '/') {
                fprintf(stderr,
                        "Path normalization with .. but no preceding relative "
                        "directory\n");
                return -1;
            }
            --resStart;
            for (resNext = resStart; resNext != resEnd && *resNext != '/'; --resNext)
                ;
            if (resNext == resStart) {
                fprintf(stderr,
                        "Path normalization with .. but no preceding relative "
                        "directory\n");
                return -1;
            }

            if (AStringResize(result, resNext - resEnd))
                return -1;
        } else if (AStringViewEqual2(&pathPart, &dots1)) {
            // Forward to next name
            for (; next != end && (*next == '\\' || *next == '/'); ++next)
                ;
        } else {
            if (AStringCatN(result, 1, &pathPart))
                return -1;
        }

        start = next;
    }

    return 0;
}

int MBSToWCS(const AStringView *pSrc, ByteBuffer *pDst) {
    INT srcLen, dstLen;

    dstLen = MultiByteToWideChar(CP_ACP, 0, pSrc->Buffer, pSrc->Length, NULL, 0);
    if (dstLen == -1) {
        fprintf(stderr, "Convert unicode string to ASCII string error, win32 error: %lu\n",
                GetLastError());
        return -1;
    }

    ByteBufferResize(pDst, (dstLen + 1) * sizeof(WCHAR));
    MultiByteToWideChar(CP_ACP, 0, pSrc->Buffer, pSrc->Length, pDst->Buffer, dstLen);
    ((WCHAR *)pDst->Buffer)[dstLen] = 0;
    return 0;
}

#pragma region[ DependsParser ]

int DependsParserAppendDependList(DependsParserContext *ctx, const AStringView *depend) {
    LPCSTR start = ctx->DependList.Buffer;
    LPCSTR end = ctx->DependList.AStrBuffer + ctx->DependList.Size;
    AString dependPathBuffer = {0};
    AStringView depend2;
    int ret = -1;

    if (NormalizeAPath(depend, &dependPathBuffer))
        goto final_cleanup;
    AStringViewInit2(&depend2, dependPathBuffer.Buffer, dependPathBuffer.Length);

    for (; start != end;) {
        if (AStringViewEqual(&depend2, start))
            return 0;
        start += strlen(start) + 1;
    }

    if (ByteBufferWrite(&ctx->DependList, depend2.Buffer, depend2.Length))
        goto final_cleanup;

    if (ByteBufferWrite(&ctx->DependList, "", 1))
        goto final_cleanup;

    ret = 0;
final_cleanup:
    AStringDeinit(&dependPathBuffer);
    return ret;
}

int DependsParserInit(DependsParserContext *ctx, const Args *args) {
    AStringView pathView;
    int ret = -1;

    ctx->Enabled = ArgsHasDepfile(args);

    if (ctx->Enabled) {
        AStringViewInit2(&pathView, args->OutputFilePath.Buffer,
                         args->OutputFilePath.Length);
        if (NormalizeAPath(&pathView, &ctx->Target))
            return -1;

        if (DependsParserAppendDependList(ctx, &args->SourceFilePath))
            return -1;
    }

    return 0;
}

int DependsParserInput(DependsParserContext *ctx, const AStringView *content,
                       BOOL handleRemaining) {
    // Opening file [*], stack top [1]
    // Current working dir [*]
    // Resolved to [*]
    const AStringView FirstLinePrefix = AStringViewCreate("Opening file [");
    const AStringView FirstLineIndent = AStringViewCreate(", stack top [");
    const AStringView SecondLinePrefix = AStringViewCreate("Current working dir [");
    const AStringView ThirdLinePrefix = AStringViewCreate("Resolved to [");
    const AStringView FinalLinePrefix =
        AStringViewCreate("compilation header save succeeded; see ");

    LPCSTR start, next, last, end;
    AStringView curr;
    int ret = -1;

    if (ctx->Enabled) {
        if (!AStringViewIsEmpty(content)) {
            if (ByteBufferCatAStringViews(&ctx->SrcContent, 1, content))
                goto final_cleanup;
        }

        start = ctx->SrcContent.AStrBuffer;
        end = ctx->SrcContent.AStrBuffer + ctx->SrcContent.Size;

        if (!handleRemaining && start != end) {
            last = end - 1;
            for (last = end - 1; last != start && *last != '\n'; --last)
                ;
            if (last == start) {
                ret = 0;
                goto final_cleanup;
            }
            end = last + 1;
        }

        while (start != end) {
            AStringViewInit2(&curr, start, end - start);

            if (AStringViewEqualAtLeast(&curr, &FirstLinePrefix)) {
                start += FirstLinePrefix.Length;
                ctx->SessionState = 1;
            } else {
                next = ReadNextLine(start, end);
                if (next != start)
                    fprintf(stdout, "%.*s", (int)(next - start), start);
                start = next;
                ++ctx->LineIndex;
                continue;
            }

            if ((start = ReadNextLine(start, end)) == end)
                break;
            ++ctx->LineIndex;

            while (start != end) {
                AStringViewInit2(&curr, start, end - start);
                if (AStringViewEqualAtLeast(&curr, &SecondLinePrefix)) {
                    start += SecondLinePrefix.Length;
                    ctx->SessionState = 2;

                    if ((start = ReadNextLine(start, end)) == end)
                        break;
                    ++ctx->LineIndex;
                } else {
                    if (ctx->SessionState != 1 && ctx->SessionState != 2) {
                        fprintf(
                            stderr,
                            "Read inline stack log line (%u) mismatched, must start with "
                            "'%s':\n%.*s\n",
                            ctx->LineIndex, SecondLinePrefix.Buffer, (int)curr.Length,
                            curr.Buffer);
                        goto relax_cleanup;
                    }
                    break;
                }
            }

            if (start != end) {
                AStringViewInit2(&curr, start, end - start);
                if (AStringViewEqualAtLeast(&curr, &ThirdLinePrefix)) {
                    start += ThirdLinePrefix.Length;
                    ctx->SessionState = 0;
                } else {
                    fprintf(stderr,
                            "Read inline stack log line (%u) mismatched, must start with "
                            "'%s':\n%.*s\n'",
                            ctx->LineIndex, ThirdLinePrefix.Buffer, (int)curr.Length,
                            curr.Buffer);
                    goto relax_cleanup;
                }
            }

            for (next = start; next != end && *next != ']'; ++next)
                ;

            AStringViewInit2(&curr, start, next - start);

            if (DependsParserAppendDependList(ctx, &curr))
                goto relax_cleanup;

            if ((start = ReadNextLine(next, end)) == end)
                break;

            ++ctx->LineIndex;
        }

    relax_cleanup:
        ByteBufferEraseRange(&ctx->SrcContent, 0, end - ctx->SrcContent.AStrBuffer);
        ret = 0;
        goto final_cleanup;
    } else {
        fprintf(stdout, "%.*s", content->Length, content->Buffer);
        ret = 0;
    }

final_cleanup:
    return ret;
}

void DependsParserDeinit(DependsParserContext *ctx) {
    ByteBufferDeinit(&ctx->SrcContent);
    AStringDeinit(&ctx->Target);
    ByteBufferDeinit(&ctx->DependList);
}

#pragma endregion[DependsParser]

int WriteDepFile(const Args *args, const DependsParserContext *depCtx) {
    const AStringView TargetPostfix = AStringViewCreate(": \\\n");
    const AStringView DependPostfix = AStringViewCreate(" \\\n");
    const AStringView DependPrefix = AStringViewCreate("    ");

    HANDLE hDepFile = INVALID_HANDLE_VALUE;
    AString depfilePathA = {0};
    AStringView depfilePathAView = {0};
    ByteBuffer depfilePathW = {0};
    ByteBuffer content = {0};
    AStringView tmpView;
    LPCSTR start, end;
    BOOL fileExists;
    ByteBuffer fileRecordContent = {0};
    LARGE_INTEGER fileSize;
    UINT64 bytesRemaining, bytesOffset;
    DWORD bytesTransfer;
    int ret = -1;

    if (ArgsHasDepfile(args)) {
        AStringViewInit2(&tmpView, depCtx->Target.Buffer, depCtx->Target.Length);
        if (ByteBufferCatAStringViews(&content, 2, &tmpView, &TargetPostfix))
            goto final_cleanup;

        start = depCtx->DependList.AStrBuffer;
        end = depCtx->DependList.AStrBuffer + depCtx->DependList.Size;
        for (; start != end;) {
            AStringViewInit(&tmpView, start);
            if (ByteBufferCatAStringViews(&content, 3, &DependPrefix, &tmpView,
                                          &DependPostfix))
                goto final_cleanup;

            start += tmpView.Length + 1;
        }

        if (NormalizeAPath(&args->DepFilePath, &depfilePathA))
            goto final_cleanup;

        AStringViewInit2(&depfilePathAView, depfilePathA.Buffer, depfilePathA.Length);
        if (MBSToWCS(&depfilePathAView, &depfilePathW))
            goto final_cleanup;

        hDepFile =
            CreateFileW((LPWSTR)depfilePathW.Buffer, GENERIC_WRITE | GENERIC_READ,
                        FILE_SHARE_READ, NULL, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
        if (hDepFile == INVALID_HANDLE_VALUE) {
            fprintf(stderr, "Failed to create depfile '%s', win32 error: %lu\n",
                    depfilePathA.Buffer, GetLastError());
            goto final_cleanup;
        }
        fileExists = GetLastError() == ERROR_ALREADY_EXISTS;
        ByteBufferDeinit(&depfilePathW);

        if (fileExists) {
            // Compare content and file record content. For simplicity, we just roughly
            // check file difference, and write to it only if content is different.
            if (GetFileSizeEx(hDepFile, &fileSize) == INVALID_FILE_SIZE) {
                fprintf(stderr, "Failed to query depfile '%s' size, win32 error: %lu\n",
                        depfilePathA.Buffer, GetLastError());
                goto final_cleanup;
            }

            if (ByteBufferResize(&fileRecordContent, fileSize.QuadPart))
                goto final_cleanup;

            bytesRemaining = fileSize.QuadPart;
            bytesOffset = 0;
            while (bytesRemaining) {
                if (!ReadFile(hDepFile, (LPBYTE)fileRecordContent.Buffer + bytesOffset,
                              min(bytesRemaining, ~0u), &bytesTransfer, NULL)) {
                    fprintf(stderr, "Read depfile '%s' failed, win32 error: %lu\n",
                            depfilePathA.Buffer, GetLastError());
                    goto final_cleanup;
                }
                bytesOffset += bytesTransfer;
                bytesRemaining -= bytesTransfer;
            }

            if (fileRecordContent.Size == content.Size &&
                memcmp(fileRecordContent.Buffer, content.Buffer, content.Size) == 0) {
                ret = 0;
                // early succeed return
                goto final_cleanup;
            }
            ByteBufferDeinit(&fileRecordContent);

            SetFilePointer(hDepFile, 0, NULL, FILE_BEGIN);
        }

        bytesRemaining = content.Size;
        bytesOffset = 0;
        while (bytesRemaining) {
            if (!WriteFile(hDepFile, (LPBYTE)content.Buffer + bytesOffset,
                           min(bytesRemaining, ~0u), &bytesTransfer, NULL)) {
                fprintf(stderr, "Write to depfile '%s' failed, win32 error: %lu\n",
                        depfilePathA.Buffer, GetLastError());
                goto final_cleanup;
            }

            bytesOffset += bytesTransfer;
            bytesRemaining -= bytesTransfer;
        }

        if (!SetEndOfFile(hDepFile)) {
            fprintf(stderr, "Failed to set depfile '%s' file size, win32 error: %lu\n",
                    depfilePathA.Buffer, GetLastError());
        }

        fprintf(stdout, "depfile save succeeded; see %s\n", depfilePathA.Buffer);
    }
    ret = 0;

final_cleanup:
    ByteBufferDeinit(&fileRecordContent);
    if (hDepFile != INVALID_HANDLE_VALUE)
        CloseHandle(hDepFile);
    ByteBufferDeinit(&content);
    ByteBufferDeinit(&depfilePathW);
    AStringDeinit(&depfilePathA);

    return ret;
}

void Usage(LPCSTR prog) {
    fprintf(stdout,
            "Usage: ShaderTool <--fxc <path>> <--options <string>> [--depfile <path>]\n"
            "                  [--relax]\n"
            "     --fxc <path>                FXC program path.\n"
            "     --options <string>          FXC command line reinterpreted to a string \n"
            "                                 with delimiter: ',', ' ' or ';'.\n"
            "     --depfile <path>            depfile output file path, if this option \n"
            "                                 not specified, ShaderTool will run FXC \n"
            "                                 directly.\n"
            "     -h,--help                   show this usage message.\n");
}

int ParseCommandLine(int argc, LPCSTR *argv, Args *args) {
    const AStringView fxcProgOpt = AStringViewCreate("--fxc");
    const AStringView fxcArgsOpt = AStringViewCreate("--options");
    const AStringView depfileOpt = AStringViewCreate("--depfile");
    UINT i;
    AStringView curr;
    AStringView fxcOptions;

    if (argc < 2)
        return -1;

    AStringViewInit(&fxcOptions, NULL);

    for (i = 1; i < argc; ++i) {
        AStringViewInit(&curr, argv[i]);
        if (AStringViewEqualAtLeast(&curr, &fxcProgOpt)) {
            if (curr.Buffer[fxcProgOpt.Length] == '=') {
                AStringViewInit2(&args->FxcProg, curr.Buffer + fxcProgOpt.Length + 1,
                                 curr.Length - fxcProgOpt.Length - 1);
            } else {
                if (i + 1 < argc) {
                    ++i;
                    AStringViewInit(&args->FxcProg, argv[i]);
                } else {
                    fprintf(stderr, "FXC program path must be specified for '%s' option\n",
                            fxcProgOpt.Buffer);
                    return -1;
                }
            }
        } else if (AStringViewEqualAtLeast(&curr, &fxcArgsOpt)) {
            if (curr.Buffer[fxcArgsOpt.Length] == '=') {
                AStringViewInit2(&fxcOptions, curr.Buffer + fxcArgsOpt.Length + 1,
                                 curr.Length - fxcArgsOpt.Length - 1);
            } else {
                if (i + 1 < argc) {
                    ++i;
                    AStringViewInit(&fxcOptions, argv[i]);
                } else {
                    fprintf(stderr, "FXC options must be specified for '%s' option\n",
                            fxcArgsOpt.Buffer);
                    return -1;
                }
            }
        } else if (AStringViewEqualAtLeast(&curr, &depfileOpt)) {
            if (curr.Buffer[depfileOpt.Length] == '=') {
                AStringViewInit2(&args->DepFilePath, curr.Buffer + depfileOpt.Length + 1,
                                 curr.Length - depfileOpt.Length - 1);
            } else {
                if (i + 1 < argc) {
                    ++i;
                    AStringViewInit(&args->DepFilePath, argv[i]);
                } else {
                    fprintf(stderr, "Depfile path must be specified for '%s' option\n",
                            depfileOpt.Buffer);
                    return -1;
                }
            }
        } else if (AStringViewEqual(&curr, "-h") == 0 ||
                   AStringViewEqual(&curr, "--help") == 0) {
            Usage(argv[0]);
            return 1;
        } else {
            fprintf(stderr, "Unknown option: ");
            for (; i < argc; ++i)
                fprintf(stderr, "%s", argv[i]);
            return -1;
        }
    }

    if (AStringViewIsEmpty(&args->FxcProg)) {
        fprintf(stderr, "FXC program must be specified\n");
        return -1;
    }

    if (AStringViewIsEmpty(&fxcOptions)) {
        fprintf(stderr, "FXC option must be specified\n");
        return -1;
    }

    if (ArgsParseFxcCommandLine(args, &fxcOptions)) {
        return -1;
    }

    if (!AStringViewIsEmpty(&args->DepFilePath)) {
        // Retrieve source and output file path from FXC options
        for (i = 0; i < args->NumFxcOptions; ++i) {
            if (AStringViewEqual(&args->FxcOptions[i], "/Fo") ||
                AStringViewEqual(&args->FxcOptions[i], "/Fh")) {
                i += 1;
                args->OutputFilePath = args->FxcOptions[i];
            }
        }

        if (AStringViewIsEmpty(&args->OutputFilePath)) {
            fprintf(stderr, "FXC output file path not specified\n");
            return -1;
        }
    }

    if (args->NumFxcOptions > 0)
        args->SourceFilePath = args->FxcOptions[args->NumFxcOptions - 1];

    if (AStringViewIsEmpty(&args->SourceFilePath)) {
        fprintf(stderr, "FXC source file path not specfied for last option\n");
        return -1;
    }

    return 0;
}

int TransformProcessCommandLine(const Args *args, ByteBuffer *cmdLine) {
    const AStringView delim = ASTRING_VIEW_INITIALIZER2(" ", 1);
    const AStringView optionEnclose = ASTRING_VIEW_INITIALIZER2("\"", 1);
    AString cmdLineA = {0};
    AStringView cmdLineViewA;
    UINT i;
    AStringView option, value;
    BOOL hasViOption;
    int ret = -1;

    if (AStringCatN(&cmdLineA, 3, &optionEnclose, &args->FxcProg, &optionEnclose))
        goto final_cleanup;

    if (ArgsHasDepfile(args)) {
        hasViOption = FALSE;
        AStringViewInit(&option, "/Vi");
        for (i = 0; i < args->NumFxcOptions; ++i)
            if (AStringViewEqual2(&args->FxcOptions[i], &option)) {
                hasViOption = TRUE;
                break;
            }

        if (!hasViOption) {
            if (AStringCatN(&cmdLineA, 2, &delim, &option))
                goto final_cleanup;
        }
    }

    for (i = 0; i < args->NumFxcOptions; ++i)
        if (AStringCatN(&cmdLineA, 2, &delim, &args->FxcOptions[i]))
            goto final_cleanup;

    AStringViewInit2(&cmdLineViewA, cmdLineA.Buffer, cmdLineA.Length);
    if (MBSToWCS(&cmdLineViewA, cmdLine))
        goto final_cleanup;

    ret = 0;

final_cleanup:
    AStringDeinit(&cmdLineA);

    return 0;
}

int RunFxc(const Args *args, int *exitCode) {
    const int TimeoutRetryTimesThreshold = 6 * 60 * 60;

    SECURITY_ATTRIBUTES saAttr;
    HANDLE hChildStd_OUT_Rd = NULL, hChildStd_OUT_Wr = NULL;
    HANDLE hEvent = NULL;
    HANDLE hSyncEvents[2];
    OVERLAPPED overlapped;
    ByteBuffer cmdLine = {0};
    STARTUPINFO si;
    PROCESS_INFORMATION pinfo = {0};
#define BUFFERSIZE 4096
    CHAR chBuf[BUFFERSIZE];
    DWORD dwBytesRead;
    int tickcount;
    int appendIo;
    DWORD rc;
    DependsParserContext dependsParserCtx = {0};
    AStringView contentSlice;
    int ret = -1;

    // Set the bInheritHandle flag so pipe handles are inherited.
    saAttr.nLength = sizeof(SECURITY_ATTRIBUTES);
    saAttr.bInheritHandle = TRUE;
    saAttr.lpSecurityDescriptor = NULL;

    // Create a pipe for the child process's STDOUT.
    if (!MyCreatePipeEx(&hChildStd_OUT_Rd, &hChildStd_OUT_Wr, &saAttr, 0,
                        FILE_FLAG_OVERLAPPED, FILE_FLAG_OVERLAPPED)) {
        fprintf(stderr, "Failed to create STDOUT pipe\n");
        goto final_cleanup;
    }

    // Ensure the read handle to the pipe for STDOUT is not inherited.
    if (!SetHandleInformation(hChildStd_OUT_Rd, HANDLE_FLAG_INHERIT, 0)) {
        fprintf(stderr, "Failed to disable STDOUT readable handle inheritent");
        goto final_cleanup;
    }

    if (!(hEvent = CreateEventW(NULL, TRUE, FALSE, NULL))) {
        fprintf(stderr, "Failed to create sync event, win32 error: %lu\n", GetLastError());
        goto final_cleanup;
    }

    // Create the child process.
    ZeroMemory(&si, sizeof(si));
    si.cb = sizeof(si);
    si.dwFlags = STARTF_USESTDHANDLES | STARTF_USEFILLATTRIBUTE | STARTF_USESHOWWINDOW;
    si.hStdError = GetStdHandle(STD_ERROR_HANDLE);
    si.hStdOutput = hChildStd_OUT_Wr;
    si.hStdInput = GetStdHandle(STD_INPUT_HANDLE);
    si.wShowWindow = SW_HIDE;

    if (TransformProcessCommandLine(args, &cmdLine)) {
        goto final_cleanup;
    }

    if (!CreateProcessW(NULL, (LPWSTR)cmdLine.Buffer, NULL, NULL, TRUE, 0, NULL, NULL, &si,
                        &pinfo)) {
        fprintf(stderr, "Failed to create FXC process, win32 error: %lu\n", GetLastError());
        goto final_cleanup;
    }
    ByteBufferDeinit(&cmdLine);

    CloseHandle(pinfo.hThread);
    pinfo.hThread = NULL;

    if (DependsParserInit(&dependsParserCtx, args))
        goto final_cleanup;

    // Asynchronous IO re-direction operation.
    ZeroMemory(&overlapped, sizeof(OVERLAPPED));
    overlapped.hEvent = hEvent;
    hSyncEvents[0] = hEvent;
    hSyncEvents[1] = pinfo.hProcess;
    tickcount = 0;
    appendIo = 1;
    for (;;) {
        if (appendIo) {
            rc = ReadFile(hChildStd_OUT_Rd, chBuf, BUFFERSIZE, NULL, &overlapped);
            if (!rc) {
                if (GetLastError() != ERROR_IO_PENDING) {
                    rc = WaitForSingleObject(
                        pinfo.hProcess, (TimeoutRetryTimesThreshold - tickcount) * 1000);
                    if (rc == WAIT_OBJECT_0) {
                        break;
                    } else if (rc == WAIT_TIMEOUT) {
                        fprintf(stderr, "Wait for FXC process timeout unexpected\n");
                        TerminateProcess(pinfo.hProcess, 1);
                        goto final_cleanup;
                    } else if (rc == WAIT_FAILED) {
                        fprintf(stderr, "Wait for FCX process failed, win32 error: %lu\n",
                                GetLastError());
                        TerminateProcess(pinfo.hProcess, 1);
                        goto final_cleanup;
                    }
                }
            }
            appendIo = 0;
        }

        // wait for IO completion or child process exit
        rc = WaitForMultipleObjects(2, hSyncEvents, FALSE, 400);
        if (rc == WAIT_TIMEOUT) {
            if (++tickcount >= TimeoutRetryTimesThreshold) {
                fprintf(stderr,
                        "Wait for output from FCX after retry %u times failed, terminate "
                        "unexpected\n",
                        TimeoutRetryTimesThreshold);
                goto final_cleanup;
            } else
                continue;
        } else if (rc == WAIT_FAILED) {
            fprintf(stderr, "Wait for FCX process failed, win32 error: %lu\n",
                    GetLastError());
            TerminateProcess(pinfo.hProcess, 1);
            goto final_cleanup;
        } else {
            if (rc == WAIT_OBJECT_0) {
                GetOverlappedResult(hChildStd_OUT_Rd, &overlapped, &dwBytesRead, FALSE);
                ResetEvent(hEvent);
                appendIo = 1;
                if (dwBytesRead == 0) {
                    // Wait for child process exit normally.
                    continue;
                }

                AStringViewInit2(&contentSlice, chBuf, dwBytesRead);
                if (DependsParserInput(&dependsParserCtx, &contentSlice, FALSE))
                    goto final_cleanup;
            } else
                break;
        }
    }

    AStringViewInit(&contentSlice, NULL);
    if (DependsParserInput(&dependsParserCtx, &contentSlice, TRUE))
        goto final_cleanup;

    if (WriteDepFile(args, &dependsParserCtx))
        goto final_cleanup;

    if (!GetExitCodeProcess(pinfo.hProcess, (DWORD *)exitCode)) {
        fprintf(stderr, "Failed to get FXC process return value, win32 error: %lu\n",
                GetLastError());
        goto final_cleanup;
    }

    ret = 0;

final_cleanup:
    DependsParserDeinit(&dependsParserCtx);
    if (pinfo.hProcess)
        CloseHandle(pinfo.hProcess);
    if (hEvent)
        CloseHandle(hEvent);
    if (hChildStd_OUT_Rd)
        CloseHandle(hChildStd_OUT_Rd);
    if (hChildStd_OUT_Wr)
        CloseHandle(hChildStd_OUT_Wr);
    ByteBufferDeinit(&cmdLine);

    return ret;
}

int main(int argc, char *argv[]) {
    Args args = {0};
    int fxcExitCode;
    int rc;
    int ret;

    ret = 1;

    rc = ParseCommandLine(argc, (LPCSTR *)argv, &args);
    if (rc == 1)
        return 1;
    else if (rc)
        goto final_cleanup;

    if (RunFxc(&args, &fxcExitCode))
        goto final_cleanup;

    ret = fxcExitCode;

final_cleanup:
    ArgsDeinit(&args);

    return ret;
}