#!/usr/bin/env python3
"""Build a 64-bit Windows GUI PE stub.

The stub reads itself, finds the last RAFIQ_PAYLOAD_v01 marker, writes the
bytes that follow to %TEMP%\\Rafiq\\RafiqUI.ps1, then launches PowerShell.
"""

from __future__ import annotations

import struct
import sys
from pathlib import Path

MAGIC = b"RAFIQ_PAYLOAD_v1"  # must be 16 bytes
assert len(MAGIC) == 16
XOR_KEY = 0xA5  # magic is stored XOR-encoded in .rdata so a naive scan won't hit it


def align(n: int, a: int) -> int:
    return (n + (a - 1)) & ~(a - 1)


class Asm:
    def __init__(self) -> None:
        self.buf = bytearray()
        self.labels: dict[str, int] = {}
        self.rel_text: list[tuple[int, str, int]] = []
        self.rel_rdata: list[tuple[int, str]] = []
        self.rel_iat: list[tuple[int, str]] = []

    def pos(self) -> int:
        return len(self.buf)

    def L(self, name: str) -> None:
        self.labels[name] = self.pos()

    def emit(self, *chunks: int | bytes) -> None:
        for c in chunks:
            if isinstance(c, int):
                self.buf.append(c & 0xFF)
            else:
                self.buf.extend(c)

    def i32(self, v: int) -> None:
        self.emit(struct.pack("<i", v))

    def u32(self, v: int) -> None:
        self.emit(struct.pack("<I", v))

    def slot32(self) -> int:
        at = self.pos()
        self.emit(b"\x00\x00\x00\x00")
        return at

    def lea_rip(self, reg: int, label: str) -> None:
        rex = 0x48
        r = reg
        if reg >= 8:
            rex |= 0x04
            r -= 8
        self.emit(rex, 0x8D, 0x05 | (r << 3))
        self.rel_rdata.append((self.slot32(), label))

    def call_iat(self, name: str) -> None:
        self.emit(0xFF, 0x15)
        self.rel_iat.append((self.slot32(), name))

    def jmp(self, label: str) -> None:
        self.emit(0xE9)
        self.rel_text.append((self.slot32(), label, 4))

    def jcc32(self, cc: int, label: str) -> None:
        """cc is the 0F second byte: 84 je, 85 jne, 87 ja, 8C jl, 83 jae, 82 jb, 88 js"""
        self.emit(0x0F, cc)
        self.rel_text.append((self.slot32(), label, 4))

    def jcc8(self, op: int, label: str) -> None:
        self.emit(op)
        at = self.pos()
        self.emit(0)
        self.rel_text.append((at, label, 1))

    def finalize(self, text_rva: int, rdata_rva: int, rlabels: dict[str, int], iat: dict[str, int]) -> None:
        for at, label, size in self.rel_text:
            target = self.labels[label]
            disp = target - (at + size)
            if size == 1:
                if disp < -128 or disp > 127:
                    raise RuntimeError(f"rel8 overflow {label} {disp}")
                self.buf[at] = disp & 0xFF
            else:
                struct.pack_into("<i", self.buf, at, disp)
        for at, label in self.rel_rdata:
            tgt = rdata_rva + rlabels[label]
            struct.pack_into("<i", self.buf, at, tgt - (text_rva + at + 4))
        for at, name in self.rel_iat:
            tgt = rdata_rva + iat[name]
            struct.pack_into("<i", self.buf, at, tgt - (text_rva + at + 4))


RAX, RCX, RDX, RBX, RSP, RBP, RSI, RDI = range(8)
R8, R9, R10, R11, R12, R13, R14, R15 = range(8, 16)


def mov_rr(a: Asm, dst: int, src: int) -> None:
    rex, rs, rd = 0x48, src, dst
    if src >= 8:
        rex |= 0x04
        rs -= 8
    if dst >= 8:
        rex |= 0x01
        rd -= 8
    a.emit(rex, 0x89, 0xC0 | (rs << 3) | rd)


def xor_rr(a: Asm, dst: int, src: int) -> None:
    rex, rs, rd = 0x48, src, dst
    if src >= 8:
        rex |= 0x04
        rs -= 8
    if dst >= 8:
        rex |= 0x01
        rd -= 8
    a.emit(rex, 0x31, 0xC0 | (rs << 3) | rd)


def xor32(a: Asm, reg: int) -> None:
    if reg < 8:
        a.emit(0x31, 0xC0 | (reg << 3) | reg)
    else:
        r = reg - 8
        a.emit(0x45, 0x31, 0xC0 | (r << 3) | r)


def mov_i32(a: Asm, reg: int, imm: int) -> None:
    if reg < 8:
        a.emit(0xB8 + reg)
    else:
        a.emit(0x41, 0xB8 + (reg - 8))
    a.u32(imm & 0xFFFFFFFF)


def add_i(a: Asm, reg: int, imm: int) -> None:
    rex, r = 0x48, reg
    if reg >= 8:
        rex |= 0x01
        r -= 8
    if -128 <= imm <= 127:
        a.emit(rex, 0x83, 0xC0 | r, imm & 0xFF)
    else:
        a.emit(rex, 0x81, 0xC0 | r)
        a.i32(imm)


def sub_i(a: Asm, reg: int, imm: int) -> None:
    rex, r = 0x48, reg
    if reg >= 8:
        rex |= 0x01
        r -= 8
    if -128 <= imm <= 127:
        a.emit(rex, 0x83, 0xE8 | r, imm & 0xFF)
    else:
        a.emit(rex, 0x81, 0xE8 | r)
        a.i32(imm)


def inc(a: Asm, reg: int) -> None:
    rex, r = 0x48, reg
    if reg >= 8:
        rex |= 0x01
        r -= 8
    a.emit(rex, 0xFF, 0xC0 | r)


def dec(a: Asm, reg: int) -> None:
    rex, r = 0x48, reg
    if reg >= 8:
        rex |= 0x01
        r -= 8
    a.emit(rex, 0xFF, 0xC8 | r)


def test_rr(a: Asm, dst: int, src: int) -> None:
    rex, rs, rd = 0x48, src, dst
    if src >= 8:
        rex |= 0x04
        rs -= 8
    if dst >= 8:
        rex |= 0x01
        rd -= 8
    a.emit(rex, 0x85, 0xC0 | (rs << 3) | rd)


def lea_r12(a: Asm, dst: int, off: int) -> None:
    r = dst
    rex = 0x49  # W+B
    if dst >= 8:
        rex |= 0x04
        r -= 8
    if off == 0:
        a.emit(rex, 0x8D, 0x04 | (r << 3), 0x24)
    elif -128 <= off <= 127:
        a.emit(rex, 0x8D, 0x44 | (r << 3), 0x24, off & 0xFF)
    else:
        a.emit(rex, 0x8D, 0x84 | (r << 3), 0x24)
        a.i32(off)


def load_r12(a: Asm, dst: int, off: int) -> None:
    r = dst
    rex = 0x49
    if dst >= 8:
        rex |= 0x04
        r -= 8
    if -128 <= off <= 127:
        a.emit(rex, 0x8B, 0x44 | (r << 3), 0x24, off & 0xFF)
    else:
        a.emit(rex, 0x8B, 0x84 | (r << 3), 0x24)
        a.i32(off)


def store_r12(a: Asm, off: int, src: int) -> None:
    r = src
    rex = 0x49
    if src >= 8:
        rex |= 0x04
        r -= 8
    if -128 <= off <= 127:
        a.emit(rex, 0x89, 0x44 | (r << 3), 0x24, off & 0xFF)
    else:
        a.emit(rex, 0x89, 0x84 | (r << 3), 0x24)
        a.i32(off)


def store32_rsp(a: Asm, off: int, imm: int) -> None:
    a.emit(0xC7, 0x44, 0x24, off & 0xFF)
    a.i32(imm)


def store_rsp(a: Asm, off: int, src: int) -> None:
    r = src
    rex = 0x48
    if src >= 8:
        rex |= 0x04
        r -= 8
    a.emit(rex, 0x89, 0x44 | (r << 3), 0x24, off & 0xFF)


def add_rr(a: Asm, dst: int, src: int) -> None:
    # add dst, src
    rex, rs, rd = 0x48, src, dst
    if src >= 8:
        rex |= 0x04
        rs -= 8
    if dst >= 8:
        rex |= 0x01
        rd -= 8
    a.emit(rex, 0x01, 0xC0 | (rs << 3) | rd)


def sub_rr(a: Asm, dst: int, src: int) -> None:
    rex, rs, rd = 0x48, src, dst
    if src >= 8:
        rex |= 0x04
        rs -= 8
    if dst >= 8:
        rex |= 0x01
        rd -= 8
    a.emit(rex, 0x29, 0xC0 | (rs << 3) | rd)


def cmp_eax_m1(a: Asm) -> None:
    a.emit(0x83, 0xF8, 0xFF)


def cmp_rax_m1(a: Asm) -> None:
    a.emit(0x48, 0x83, 0xF8, 0xFF)


def copy_wstr(a: Asm, loop: str) -> None:
    a.L(loop)
    a.emit(0x66, 0xAD)  # lodsw
    a.emit(0x66, 0xAB)  # stosw
    a.emit(0x66, 0x85, 0xC0)  # test ax,ax
    a.jcc8(0x75, loop)


def build_code() -> Asm:
    a = Asm()
    a.L("entry")
    # Align stack. Entry RSP≡8; sub 0x88 => RSP≡0.
    sub_i(a, RSP, 0x88)

    # work = VirtualAlloc(NULL, 0x10000, 0x3000, 4)
    xor32(a, RCX)
    mov_i32(a, RDX, 0x10000)
    mov_i32(a, R8, 0x3000)
    mov_i32(a, R9, 4)
    a.call_iat("VirtualAlloc")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")
    mov_rr(a, R12, RAX)

    # GetModuleFileNameW(NULL, work, 512)
    xor32(a, RCX)
    lea_r12(a, RDX, 0)
    mov_i32(a, R8, 512)
    a.call_iat("GetModuleFileNameW")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    # h = CreateFileW(work, GENERIC_READ, share 7, NULL, OPEN_EXISTING, NORMAL, NULL)
    lea_r12(a, RCX, 0)
    mov_i32(a, RDX, 0x80000000)
    mov_i32(a, R8, 7)
    xor32(a, R9)
    store32_rsp(a, 0x20, 3)
    store32_rsp(a, 0x28, 0x80)
    xor32(a, RAX)
    store_rsp(a, 0x30, RAX)
    a.call_iat("CreateFileW")
    cmp_rax_m1(a)
    a.jcc32(0x84, "fail")
    mov_rr(a, R13, RAX)  # hFile

    # size = GetFileSize(h, NULL)
    mov_rr(a, RCX, R13)
    xor32(a, RDX)
    a.call_iat("GetFileSize")
    cmp_eax_m1(a)
    a.jcc32(0x84, "fail")
    # zero-extend already; save in r14
    mov_rr(a, R14, RAX)
    test_rr(a, R14, R14)
    a.jcc32(0x84, "fail")

    # buf = VirtualAlloc(NULL, size, 0x3000, 4)
    xor32(a, RCX)
    mov_rr(a, RDX, R14)
    mov_i32(a, R8, 0x3000)
    mov_i32(a, R9, 4)
    a.call_iat("VirtualAlloc")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")
    mov_rr(a, R15, RAX)

    # ReadFile(h, buf, size, &work+0x2000, NULL)
    mov_rr(a, RCX, R13)
    mov_rr(a, RDX, R15)
    mov_rr(a, R8, R14)
    lea_r12(a, R9, 0x2000)
    xor32(a, RAX)
    store_rsp(a, 0x20, RAX)
    a.call_iat("ReadFile")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    mov_rr(a, RCX, R13)
    a.call_iat("CloseHandle")

    # Decode 16-byte magic from rdata into work+0x2100
    a.lea_rip(RSI, "magic_xor")
    lea_r12(a, RDI, 0x2100)
    mov_i32(a, RCX, 16)
    a.L("decmag")
    a.emit(0xAC)  # lodsb
    a.emit(0x34, XOR_KEY)  # xor al, key
    a.emit(0xAA)  # stosb
    a.emit(0xE2, 0xF9)  # loop decmag  (rel8, loop is 7 bytes back: AC 34 xx AA E2 F9 = 6, wait)
    # loop target: after we emit E2, displacement is computed. Use label instead.
    # The 0xF9 is a guess — patch properly:
    # I'll replace the raw loop with jcc8.

    # Oops: already emitted a wrong loop. Build decode with a proper labeled loop instead.
    # The above 4 emits already went in. Let me not use loop. I'll rewrite decode below
    # by jumping over the bad bytes... too messy. The file is generated from this function
    # so I must not emit the broken loop. I'll reconstruct decode now without the raw loop —
    # I need to remove those emits. I'll rewrite this whole function carefully without dead code.

    return a  # placeholder, rewritten below


def build_code() -> Asm:
    a = Asm()
    a.L("entry")
    a.emit(0xFC)  # cld
    sub_i(a, RSP, 0x88)

    xor32(a, RCX)
    mov_i32(a, RDX, 0x10000)
    mov_i32(a, R8, 0x3000)
    mov_i32(a, R9, 4)
    a.call_iat("VirtualAlloc")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")
    mov_rr(a, R12, RAX)

    xor32(a, RCX)
    lea_r12(a, RDX, 0)
    mov_i32(a, R8, 512)
    a.call_iat("GetModuleFileNameW")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    lea_r12(a, RCX, 0)
    mov_i32(a, RDX, 0x80000000)
    mov_i32(a, R8, 7)
    xor32(a, R9)
    store32_rsp(a, 0x20, 3)
    store32_rsp(a, 0x28, 0x80)
    xor32(a, RAX)
    store_rsp(a, 0x30, RAX)
    a.call_iat("CreateFileW")
    cmp_rax_m1(a)
    a.jcc32(0x84, "fail")
    mov_rr(a, R13, RAX)

    mov_rr(a, RCX, R13)
    xor32(a, RDX)
    a.call_iat("GetFileSize")
    cmp_eax_m1(a)
    a.jcc32(0x84, "fail")
    mov_rr(a, R14, RAX)
    test_rr(a, R14, R14)
    a.jcc32(0x84, "fail")

    xor32(a, RCX)
    mov_rr(a, RDX, R14)
    mov_i32(a, R8, 0x3000)
    mov_i32(a, R9, 4)
    a.call_iat("VirtualAlloc")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")
    mov_rr(a, R15, RAX)

    mov_rr(a, RCX, R13)
    mov_rr(a, RDX, R15)
    mov_rr(a, R8, R14)
    lea_r12(a, R9, 0x2000)
    xor32(a, RAX)
    store_rsp(a, 0x20, RAX)
    a.call_iat("ReadFile")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    mov_rr(a, RCX, R13)
    a.call_iat("CloseHandle")

    # Decode magic into work+0x2100
    a.lea_rip(RSI, "magic_xor")
    lea_r12(a, RDI, 0x2100)
    xor32(a, RBX)
    a.L("decmag")
    # mov al, [rsi+rbx]
    a.emit(0x8A, 0x04, 0x1E)  # mov al, [rsi+rbx]
    a.emit(0x34, XOR_KEY)
    # mov [rdi+rbx], al
    a.emit(0x88, 0x04, 0x1F)
    inc(a, RBX)
    # cmp rbx, 16
    a.emit(0x48, 0x83, 0xFB, 0x10)
    a.jcc8(0x7C, "decmag")  # jl

    # Search LAST occurrence: rbx from size-16 down to 0
    mov_rr(a, RBX, R14)
    sub_i(a, RBX, 16)
    a.L("scan")
    # rsi = file+rbx
    mov_rr(a, RSI, R15)
    add_rr(a, RSI, RBX)
    lea_r12(a, RDI, 0x2100)
    mov_i32(a, RCX, 16)
    a.emit(0xF3, 0xA6)  # repe cmpsb
    a.jcc8(0x74, "found")
    test_rr(a, RBX, RBX)
    a.jcc32(0x84, "fail")  # jz fail
    dec(a, RBX)
    a.jmp("scan")

    a.L("found")
    # payload = file + rbx + 16  -> r13
    mov_rr(a, R13, R15)
    add_rr(a, R13, RBX)
    add_i(a, R13, 16)
    # plen = size - rbx - 16
    mov_rr(a, RAX, R14)
    sub_rr(a, RAX, RBX)
    sub_i(a, RAX, 16)
    store_r12(a, 0x2008, RAX)
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    # GetTempPathW(512, work+0x400)
    mov_i32(a, RCX, 512)
    lea_r12(a, RDX, 0x400)
    a.call_iat("GetTempPathW")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    # dir = temp + "Rafiq"
    lea_r12(a, RDI, 0x800)
    lea_r12(a, RSI, 0x400)
    copy_wstr(a, "c1")
    sub_i(a, RDI, 2)
    a.lea_rip(RSI, "s_rafiq")
    copy_wstr(a, "c2")

    # ps1 = temp + "Rafiq\\RafiqUI.ps1"
    lea_r12(a, RDI, 0xC00)
    lea_r12(a, RSI, 0x400)
    copy_wstr(a, "c3")
    sub_i(a, RDI, 2)
    a.lea_rip(RSI, "s_ps1rel")
    copy_wstr(a, "c4")

    lea_r12(a, RCX, 0x800)
    xor32(a, RDX)
    a.call_iat("CreateDirectoryW")

    lea_r12(a, RCX, 0xC00)
    mov_i32(a, RDX, 0x40000000)
    xor32(a, R8)
    xor32(a, R9)
    store32_rsp(a, 0x20, 2)
    store32_rsp(a, 0x28, 0x80)
    xor32(a, RAX)
    store_rsp(a, 0x30, RAX)
    a.call_iat("CreateFileW")
    cmp_rax_m1(a)
    a.jcc32(0x84, "fail")
    mov_rr(a, RBX, RAX)

    mov_rr(a, RCX, RBX)
    mov_rr(a, RDX, R13)
    load_r12(a, R8, 0x2008)
    lea_r12(a, R9, 0x2000)
    xor32(a, RAX)
    store_rsp(a, 0x20, RAX)
    a.call_iat("WriteFile")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    mov_rr(a, RCX, RBX)
    a.call_iat("CloseHandle")

    # cmdline
    lea_r12(a, RDI, 0x1000)
    a.lea_rip(RSI, "s_cmdpref")
    copy_wstr(a, "c5")
    sub_i(a, RDI, 2)
    lea_r12(a, RSI, 0xC00)
    copy_wstr(a, "c6")
    sub_i(a, RDI, 2)
    a.lea_rip(RSI, "s_quote")
    copy_wstr(a, "c7")

    # STARTUPINFO / PROCESS_INFORMATION in work+0x3000
    lea_r12(a, RDI, 0x3000)
    mov_i32(a, RCX, 160)
    xor32(a, RAX)
    a.emit(0xF3, 0xAA)
    mov_i32(a, RAX, 104)
    a.emit(0x41, 0x89, 0x84, 0x24)
    a.i32(0x3000)  # cb
    mov_i32(a, RAX, 1)
    a.emit(0x41, 0x89, 0x84, 0x24)
    a.i32(0x3000 + 60)  # dwFlags

    xor32(a, RCX)
    lea_r12(a, RDX, 0x1000)
    xor32(a, R8)
    xor32(a, R9)
    store32_rsp(a, 0x20, 0)
    store32_rsp(a, 0x28, 0x08000000)
    xor32(a, RAX)
    store_rsp(a, 0x30, RAX)
    store_rsp(a, 0x38, RAX)
    lea_r12(a, RAX, 0x3000)
    store_rsp(a, 0x40, RAX)
    lea_r12(a, RAX, 0x3000 + 104)
    store_rsp(a, 0x48, RAX)
    a.call_iat("CreateProcessW")
    test_rr(a, RAX, RAX)
    a.jcc32(0x84, "fail")

    load_r12(a, RCX, 0x3000 + 104)
    mov_i32(a, RDX, 0xFFFFFFFF)
    a.call_iat("WaitForSingleObject")

    xor32(a, RCX)
    a.call_iat("ExitProcess")

    a.L("fail")
    xor32(a, RCX)
    a.lea_rip(RDX, "s_err")
    a.lea_rip(R8, "s_title")
    mov_i32(a, R9, 0x10)
    a.call_iat("MessageBoxW")
    mov_i32(a, RCX, 1)
    a.call_iat("ExitProcess")
    return a


def wstr(s: str) -> bytes:
    return s.encode("utf-16le") + b"\x00\x00"


def build_rdata() -> tuple[bytearray, dict[str, int], dict[str, int], int, tuple]:
    k32 = [
        "GetModuleFileNameW",
        "VirtualAlloc",
        "CreateFileW",
        "GetFileSize",
        "ReadFile",
        "WriteFile",
        "CloseHandle",
        "GetTempPathW",
        "CreateDirectoryW",
        "CreateProcessW",
        "WaitForSingleObject",
        "ExitProcess",
    ]
    u32 = ["MessageBoxW"]
    buf = bytearray()
    labels: dict[str, int] = {}

    def emit(b: bytes) -> int:
        off = len(buf)
        buf.extend(b)
        return off

    def pad2() -> None:
        if len(buf) & 1:
            buf.append(0)

    def pad8() -> None:
        while len(buf) % 8:
            buf.append(0)

    pad8()
    desc_off = emit(b"\x00" * 60)

    def thunks(names: list[str]) -> tuple[int, int, list[int]]:
        pad8()
        ilt = len(buf)
        for _ in names:
            buf.extend(b"\x00" * 8)
        buf.extend(b"\x00" * 8)
        pad8()
        iat = len(buf)
        for _ in names:
            buf.extend(b"\x00" * 8)
        buf.extend(b"\x00" * 8)
        nrvas = []
        for n in names:
            pad2()
            nrvas.append(len(buf))
            buf.extend(struct.pack("<H", 0) + n.encode("ascii") + b"\x00")
        return ilt, iat, nrvas

    ilt1, iat1, n1 = thunks(k32)
    ilt2, iat2, n2 = thunks(u32)
    pad2()
    dll1 = emit(b"kernel32.dll\x00")
    pad2()
    dll2 = emit(b"user32.dll\x00")

    labels["magic_xor"] = emit(bytes(b ^ XOR_KEY for b in MAGIC))
    labels["s_rafiq"] = emit(wstr("Rafiq"))
    labels["s_ps1rel"] = emit(wstr("Rafiq\\RafiqUI.ps1"))
    labels["s_cmdpref"] = emit(
        wstr('powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "')
    )
    labels["s_quote"] = emit(wstr('"'))
    labels["s_title"] = emit(wstr("Rafiq"))
    labels["s_err"] = emit(wstr("Rafiq could not start. Right-click RafiqUI.ps1 and run with PowerShell."))

    iat = {n: iat1 + i * 8 for i, n in enumerate(k32)}
    iat["MessageBoxW"] = iat2
    meta = (ilt1, iat1, n1, dll1, ilt2, iat2, n2, dll2, k32, u32)
    return buf, labels, iat, desc_off, meta


def patch_imports(rdata: bytearray, desc_off: int, rva: int, meta) -> None:
    ilt1, iat1, n1, dll1, ilt2, iat2, n2, dll2, k32, u32 = meta

    def desc(off: int, orig: int, name: int, first: int) -> None:
        struct.pack_into("<IIIII", rdata, off, rva + orig, 0, 0, rva + name, rva + first)

    desc(desc_off, ilt1, dll1, iat1)
    desc(desc_off + 20, ilt2, dll2, iat2)
    for i, off in enumerate(n1):
        struct.pack_into("<Q", rdata, ilt1 + i * 8, rva + off)
        struct.pack_into("<Q", rdata, iat1 + i * 8, rva + off)
    for i, off in enumerate(n2):
        struct.pack_into("<Q", rdata, ilt2 + i * 8, rva + off)
        struct.pack_into("<Q", rdata, iat2 + i * 8, rva + off)


def build_pe(payload: bytes) -> bytes:
    a = build_code()
    rdata, labels, iat, desc_off, meta = build_rdata()

    FILE_ALIGN, SECT_ALIGN, HDR = 0x200, 0x1000, 0x200
    text_rva = 0x1000
    text_raw = align(len(a.buf), FILE_ALIGN)
    rdata_rva = align(text_rva + len(a.buf), SECT_ALIGN)
    rdata_raw = align(len(rdata), FILE_ALIGN)
    size_of_image = align(rdata_rva + len(rdata), SECT_ALIGN)

    a.finalize(text_rva, rdata_rva, labels, iat)
    patch_imports(rdata, desc_off, rdata_rva, meta)

    dos = bytearray(0x80)
    dos[0:2] = b"MZ"
    struct.pack_into("<H", dos, 0x3C, 0x80)

    pe = bytearray(dos)
    pe += b"PE\x00\x00"
    pe += struct.pack("<HHIIIHH", 0x8664, 2, 0, 0, 0, 0xF0, 0x0022)

    opt = bytearray(0xF0)
    struct.pack_into("<H", opt, 0, 0x20B)
    opt[2] = 14
    struct.pack_into("<I", opt, 4, text_raw)
    struct.pack_into("<I", opt, 8, rdata_raw)
    struct.pack_into("<I", opt, 16, text_rva)
    struct.pack_into("<I", opt, 20, text_rva)
    struct.pack_into("<Q", opt, 24, 0x140000000)
    struct.pack_into("<I", opt, 32, SECT_ALIGN)
    struct.pack_into("<I", opt, 36, FILE_ALIGN)
    struct.pack_into("<HH", opt, 40, 6, 0)
    struct.pack_into("<HH", opt, 44, 1, 0)
    struct.pack_into("<HH", opt, 48, 6, 0)
    struct.pack_into("<I", opt, 56, size_of_image)
    struct.pack_into("<I", opt, 60, HDR)
    struct.pack_into("<H", opt, 68, 2)  # GUI
    struct.pack_into("<H", opt, 70, 0x0100)  # NX
    struct.pack_into("<Q", opt, 72, 0x100000)
    struct.pack_into("<Q", opt, 80, 0x1000)
    struct.pack_into("<Q", opt, 88, 0x100000)
    struct.pack_into("<Q", opt, 96, 0x1000)
    struct.pack_into("<I", opt, 108, 16)
    struct.pack_into("<II", opt, 112 + 8, rdata_rva + desc_off, 60)
    struct.pack_into("<II", opt, 112 + 12 * 8, rdata_rva + meta[1], (len(meta[8]) + 1) * 8)
    pe += opt

    def sect(name: bytes, vsize: int, va: int, rawsize: int, rawptr: int, ch: int) -> bytes:
        return name[:8].ljust(8, b"\x00") + struct.pack("<IIIIIIHHI", vsize, va, rawsize, rawptr, 0, 0, 0, 0, ch)

    pe += sect(b".text", len(a.buf), text_rva, text_raw, HDR, 0x60000020)
    pe += sect(b".rdata", len(rdata), rdata_rva, rdata_raw, HDR + text_raw, 0x40000040)
    if len(pe) > HDR:
        raise RuntimeError(f"headers {len(pe)} > {HDR}")
    pe += b"\x00" * (HDR - len(pe))
    pe += bytes(a.buf).ljust(text_raw, b"\x00")
    pe += bytes(rdata).ljust(rdata_raw, b"\x00")
    return bytes(pe) + MAGIC + payload


def main() -> int:
    if len(sys.argv) < 3:
        print("usage: mkexe.py payload.ps1 out.exe")
        return 2
    payload = Path(sys.argv[1]).read_bytes()
    if not payload.startswith(b"\xef\xbb\xbf"):
        payload = b"\xef\xbb\xbf" + payload
    exe = build_pe(payload)
    Path(sys.argv[2]).write_bytes(exe)
    print(f"wrote {sys.argv[2]} ({len(exe)} bytes), stub {exe.find(MAGIC)} bytes")
    import pefile

    pe = pefile.PE(data=exe[: exe.find(MAGIC)])
    print("Machine", hex(pe.FILE_HEADER.Machine), "Entry", hex(pe.OPTIONAL_HEADER.AddressOfEntryPoint))
    print("Subsystem", pe.OPTIONAL_HEADER.Subsystem, "NX", hex(pe.OPTIONAL_HEADER.DllCharacteristics))
    for s in pe.sections:
        print(" section", s.Name.decode(errors="ignore").strip("\x00"), "va", hex(s.VirtualAddress), "raw", s.SizeOfRawData)
    pe.parse_data_directories()
    for e in pe.DIRECTORY_ENTRY_IMPORT:
        print("import", e.dll.decode())
        for imp in e.imports:
            print("   ", (imp.name or b"?").decode())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
