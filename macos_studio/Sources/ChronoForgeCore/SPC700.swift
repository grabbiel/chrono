// Native Swift port of sony-spc700-python's core.py (MIT).
// Copyright (c) 2026 Gustavo Franco. See ThirdParty/sony-spc700-python-LICENSE.
// Source pinned at 91c0576a00bd7eae09847f8f34bd4ff2dfc46773.
// Each bus operation consumes one CPU cycle, including dummy reads and waits.

/// Implementations perform the access first, then advance attached devices by
/// one clock. All addresses and write values have already been masked by CPU.
/// This interface has no DSP, timer or memory-map policy of its own.
public protocol SPC700Bus: AnyObject {
    func read(_ address: UInt16) -> UInt8
    func write(_ address: UInt16, _ value: UInt8)
    func idle()
}

/// Mutable, single-owner CPU. Use one instance on one execution thread.
/// Defaults are a deterministic test state, not claimed hardware power-on state.
public final class SPC700 {
    public struct Registers: Codable, Equatable, Sendable {
        public var pc: UInt16
        public var a, x, y, sp, psw: UInt8
        public init(pc: UInt16 = 0, a: UInt8 = 0, x: UInt8 = 0, y: UInt8 = 0,
                    sp: UInt8 = 0xFF, psw: UInt8 = 0) {
            self.pc = pc; self.a = a; self.x = x; self.y = y; self.sp = sp; self.psw = psw
        }
    }
    public var registers: Registers
    public private(set) var cycles = 0
    public private(set) var stopped = false
    private let bus: any SPC700Bus
    private typealias Mode = SPC700ISA.Mode
    private typealias Op = SPC700ISA.Operation

    public init(bus: any SPC700Bus, registers: Registers = Registers()) {
        self.bus = bus; self.registers = registers
    }

    private var a: Int { get { Int(registers.a) } set { registers.a = UInt8(truncatingIfNeeded: newValue) } }
    private var x: Int { get { Int(registers.x) } set { registers.x = UInt8(truncatingIfNeeded: newValue) } }
    private var y: Int { get { Int(registers.y) } set { registers.y = UInt8(truncatingIfNeeded: newValue) } }
    private var sp: Int { get { Int(registers.sp) } set { registers.sp = UInt8(truncatingIfNeeded: newValue) } }
    private var pc: Int { get { Int(registers.pc) } set { registers.pc = UInt16(truncatingIfNeeded: newValue) } }
    private var ya: Int { get { y << 8 | a } set { a = newValue; y = newValue >> 8 } }
    private func flag(_ mask: UInt8) -> Bool { registers.psw & mask != 0 }
    private func flag(_ mask: UInt8, _ set: Bool) {
        if set { registers.psw |= mask } else { registers.psw &= ~mask }
    }
    private var carry: Bool { get { flag(1) } set { flag(1, newValue) } }
    private func direct(_ offset: Int) -> Int { (flag(0x20) ? 0x100 : 0) | (offset & 255) }

    @discardableResult private func read(_ address: Int) -> Int {
        let value = bus.read(UInt16(truncatingIfNeeded: address)); cycles += 1
        return Int(value)
    }
    private func write(_ address: Int, _ value: Int) {
        bus.write(UInt16(truncatingIfNeeded: address), UInt8(truncatingIfNeeded: value)); cycles += 1
    }
    private func idle(_ count: Int = 1) {
        for _ in 0..<count { bus.idle(); cycles += 1 }
    }
    private func store(_ address: Int, _ value: Int) { read(address); write(address, value) }
    private func fetch() -> Int { let value = read(pc); pc += 1; return value }
    private func fetchWord() -> Int { let low = fetch(); return low | fetch() << 8 }
    private func readWord(_ address: Int) -> Int { let low = read(address); return low | read(address + 1) << 8 }
    private func directWord(_ address: Int) -> Int {
        let low = read(address); return low | read((address & 0xFF00) | ((address + 1) & 255)) << 8
    }
    private func push(_ value: Int) { write(0x100 | sp, value); sp -= 1 }
    private func pull() -> Int { sp += 1; return read(0x100 | sp) }
    private func pushWord(_ value: Int) { push(value >> 8); push(value) }
    private func pullWord() -> Int { let low = pull(); return low | pull() << 8 }

    @discardableResult private func nz(_ value: Int) -> Int {
        flag(0x80, value & 0x80 != 0); flag(2, value & 255 == 0); return value & 255
    }
    @discardableResult private func nzWord(_ value: Int) -> Int {
        flag(0x80, value & 0x8000 != 0); flag(2, value & 0xFFFF == 0); return value & 0xFFFF
    }

    /// Restores a supplied state without memory accesses. The owner is
    /// responsible for restoring RAM, DSP and timers alongside it.
    public func restore(_ state: Registers) { registers = state; cycles = 0; stopped = false }

    /// Execute one instruction. A held CPU consumes no clocks here; run(cycles:)
    /// advances the bus while held so attached timers/DSP can continue running.
    @discardableResult public func step() -> Int {
        guard !stopped else { return 0 }
        let before = cycles, opcode = fetch()
        let instruction = SPC700ISA.instructions[opcode]
        if instruction.size == 1 { read(pc) }
        execute(instruction.operation, instruction.mode, opcode)
        return cycles - before
    }

    /// May overshoot by the last instruction's clocks. Nonpositive budgets do nothing.
    @discardableResult public func run(cycles budget: Int) -> Int {
        let before = cycles
        while cycles - before < budget {
            if stopped { idle() } else { step() }
        }
        return cycles - before
    }

    private func address(_ mode: Mode) -> Int {
        switch mode {
        case .dp, .dp_bit, .dp_a, .dp_x, .dp_y, .dp_ya, .a_dp, .x_dp, .y_dp:
            return direct(fetch())
        case .dpx, .dpx_a, .dpx_y, .a_dpx, .y_dpx:
            let offset = fetch(); idle(); return direct(offset + x)
        case .dpy_x, .x_dpy:
            let offset = fetch(); idle(); return direct(offset + y)
        case .abs, .abs_a, .abs_x, .abs_y, .a_abs, .x_abs, .y_abs: return fetchWord()
        case .absx_a, .a_absx:
            let base = fetchWord(); idle(); return (base + x) & 0xFFFF
        case .absy_a, .a_absy:
            let base = fetchWord(); idle(); return (base + y) & 0xFFFF
        case .idx_a, .a_idx:
            let offset = fetch(); idle(); return directWord(direct(offset + x))
        case .a_idy:
            let offset = fetch(); idle(); return (directWord(direct(offset)) + y) & 0xFFFF
        case .idy_a:
            let pointer = directWord(direct(fetch())); idle(); return (pointer + y) & 0xFFFF
        case .ix_a, .a_ix, .ixinc_a, .a_ixinc: return direct(x)
        default: preconditionFailure("invalid SPC700 address mode")
        }
    }
    private func source(_ mode: Mode) -> Int {
        switch mode {
        case .a_imm, .x_imm, .y_imm, .dp_imm: return fetch()
        case .ix_iy: return read(direct(y))
        case .dp_dp: return read(direct(fetch()))
        default: return read(address(mode))
        }
    }
    private func adc(_ first: Int, _ second: Int) -> Int {
        let result = first + second + (carry ? 1 : 0)
        carry = result > 255
        flag(8, (first ^ second ^ result) & 0x10 != 0)
        flag(0x40, (~(first ^ second) & (first ^ result) & 0x80) != 0)
        return nz(result)
    }
    private func sbc(_ first: Int, _ second: Int) -> Int {
        let result = first - second - (carry ? 0 : 1)
        carry = result >= 0
        flag(8, (first ^ second ^ result) & 0x10 == 0)
        flag(0x40, ((first ^ second) & (first ^ result) & 0x80) != 0)
        return nz(result)
    }
    private func compare(_ first: Int, _ second: Int) { carry = first >= second; nz(first - second) }
    private func alu(_ op: Op, _ first: Int, _ second: Int) -> Int? {
        switch op {
        case .adc: return adc(first, second)
        case .sbc: return sbc(first, second)
        case .cmp: compare(first, second); return nil
        case .and: return nz(first & second)
        case .or: return nz(first | second)
        case .eor: return nz(first ^ second)
        default: preconditionFailure("invalid SPC700 ALU operation")
        }
    }
    private func accumulate(_ op: Op, _ mode: Mode) {
        if mode == .dp_imm || mode == .dp_dp || mode == .ix_iy {
            let value = source(mode), dest = mode == .ix_iy ? direct(x) : direct(fetch())
            if let result = alu(op, read(dest), value) { write(dest, result) } else { idle() }
        } else if let result = alu(op, a, source(mode)) { a = result }
    }
    private func modify(_ op: Op, _ value: Int) -> Int {
        let oldCarry = carry ? 1 : 0
        switch op {
        case .inc: return nz(value + 1)
        case .dec: return nz(value - 1)
        case .asl: carry = value & 128 != 0; return nz(value << 1)
        case .lsr: carry = value & 1 != 0; return nz(value >> 1)
        case .rol: carry = value & 128 != 0; return nz(value << 1 | oldCarry)
        case .ror: carry = value & 1 != 0; return nz(value >> 1 | oldCarry << 7)
        default: preconditionFailure("invalid SPC700 modify operation")
        }
    }
    private func wordOperand(pause: Bool = true) -> Int {
        let addr = direct(fetch()), low = read(addr)
        if pause { idle() }
        return low | read((addr & 0xFF00) | ((addr + 1) & 255)) << 8
    }
    private func branch(_ taken: Bool) {
        let offset = fetch()
        if taken { idle(2); pc += offset >= 128 ? offset - 256 : offset }
    }

    private func move(_ mode: Mode) {
        switch mode {
        case .a_imm: a = nz(fetch())
        case .x_imm: x = nz(fetch())
        case .y_imm: y = nz(fetch())
        case .a_dp, .a_dpx, .a_abs, .a_absx, .a_absy, .a_idx, .a_idy, .a_ix: a = nz(read(address(mode)))
        case .a_ixinc: a = nz(read(direct(x))); idle(); x += 1
        case .x_dp, .x_dpy, .x_abs: x = nz(read(address(mode)))
        case .y_dp, .y_dpx, .y_abs: y = nz(read(address(mode)))
        case .a_x: a = nz(x)
        case .a_y: a = nz(y)
        case .x_a: x = nz(a)
        case .y_a: y = nz(a)
        case .x_sp: x = nz(sp)
        case .sp_x: sp = x
        case .ixinc_a: idle(); write(direct(x), a); x += 1
        case .dp_dp:
            let value = read(direct(fetch())); write(direct(fetch()), value)
        case .dp_imm:
            let value = fetch(); store(direct(fetch()), value)
        case .dp_x, .dpy_x, .abs_x: store(address(mode), x)
        case .dp_y, .dpx_y, .abs_y: store(address(mode), y)
        default: store(address(mode), a)
        }
    }

    private func execute(_ op: Op, _ mode: Mode, _ opcode: Int) {
        switch op {
        case .nop: break
        case .mov: move(mode)
        case .adc, .sbc, .and, .or, .eor: accumulate(op, mode)
        case .cmp:
            switch mode {
            case .x_imm, .x_dp, .x_abs: compare(x, source(mode))
            case .y_imm, .y_dp, .y_abs: compare(y, source(mode))
            default: accumulate(op, mode)
            }
        case .inc, .dec, .asl, .lsr, .rol, .ror:
            switch mode {
            case .a: a = modify(op, a)
            case .x: x = modify(op, x)
            case .y: y = modify(op, y)
            default:
                let dest = address(mode); write(dest, modify(op, read(dest)))
            }
        case .movw:
            if mode == .ya_dp { ya = nzWord(wordOperand()) }
            else {
                let dest = direct(fetch()); read(dest)
                write(dest, a); write((dest & 0xFF00) | ((dest + 1) & 255), y)
            }
        case .addw, .subw:
            let value = wordOperand(); carry = op == .subw
            let low = op == .addw ? adc(a, value & 255) : sbc(a, value & 255)
            let high = op == .addw ? adc(y, value >> 8) : sbc(y, value >> 8)
            ya = high << 8 | low; flag(2, ya == 0)
        case .cmpw:
            let value = wordOperand(pause: false); carry = ya >= value; nzWord(ya - value)
        case .incw, .decw:
            let dest = direct(fetch()), highAddr = (dest & 0xFF00) | ((dest + 1) & 255)
            let low = read(dest) + (op == .incw ? 1 : -1)
            write(dest, low)
            let high = (read(highAddr) + (low < 0 ? -1 : (low > 255 ? 1 : 0))) & 255
            write(highAddr, high); nzWord(high << 8 | low & 255)
        case .mul: idle(7); ya = y * a; nz(y)
        case .div:
            idle(10)
            let dividend = ya, divisor = x
            flag(8, (divisor & 15) <= (y & 15)); flag(0x40, y >= divisor)
            if y < divisor * 2 { a = dividend / divisor; y = dividend % divisor }
            else {
                a = 255 - (dividend - divisor * 512) / (256 - divisor)
                y = divisor + (dividend - divisor * 512) % (256 - divisor)
            }
            nz(a)
        case .xcn: idle(3); a = nz(a >> 4 | a << 4)
        case .daa:
            idle()
            if carry || a > 0x99 { a += 0x60; carry = true }
            if flag(8) || a & 15 > 9 { a += 6 }; nz(a)
        case .das:
            idle()
            if !carry || a > 0x99 { a -= 0x60; carry = false }
            if !flag(8) || a & 15 > 9 { a -= 6 }; nz(a)
        case .bra: branch(true)
        case .beq: branch(flag(2))
        case .bne: branch(!flag(2))
        case .bcs: branch(carry)
        case .bcc: branch(!carry)
        case .bvs: branch(flag(0x40))
        case .bvc: branch(!flag(0x40))
        case .bmi: branch(flag(0x80))
        case .bpl: branch(!flag(0x80))
        case .bbs, .bbc:
            let value = read(direct(fetch())); idle()
            branch((value & (1 << (opcode >> 5)) != 0) == (op == .bbs))
        case .cbne:
            let value = read(address(mode == .dpx_rel ? .dpx : .dp)); idle(); branch(value != a)
        case .dbnz:
            if mode == .y_rel { read(pc); idle(); y -= 1; branch(y != 0) }
            else {
                let dest = direct(fetch()), result = (read(dest) - 1) & 255
                write(dest, result); branch(result != 0)
            }
        case .jmp:
            let target = fetchWord()
            if mode == .abs_indirect_x { idle(); pc = readWord((target + x) & 0xFFFF) } else { pc = target }
        case .call:
            let target = fetchWord(); idle(); pushWord(pc); idle(2); pc = target
        case .pcall:
            let target = fetch(); idle(); pushWord(pc); idle(); pc = 0xFF00 | target
        case .tcall:
            idle(); pushWord(pc); idle(); pc = readWord(0xFFDE - (opcode >> 4) * 2)
        case .brk:
            pushWord(pc); push(Int(registers.psw)); idle()
            flag(0x10, true); flag(4, false); pc = readWord(0xFFDE)
        case .ret: idle(); pc = pullWord()
        case .reti: idle(); registers.psw = UInt8(pull()); pc = pullWord()
        case .push:
            push(mode == .a ? a : mode == .x ? x : mode == .y ? y : Int(registers.psw)); idle()
        case .pop:
            idle(); let value = pull()
            switch mode {
            case .a: a = value
            case .x: x = value
            case .y: y = value
            default: registers.psw = UInt8(value)
            }
        case .set1, .clr1:
            let dest = direct(fetch()), held = read(dest), bit = 1 << (opcode >> 5)
            write(dest, op == .set1 ? held | bit : held & ~bit)
        case .tset, .tclr:
            let dest = fetchWord(), held = read(dest); read(dest)
            write(dest, op == .tset ? held | a : held & ~a); nz(a - held)
        case .and1, .or1, .eor1, .mov1, .not1:
            let packed = fetchWord(), dest = packed & 0x1FFF, mask = 1 << (packed >> 13)
            let held = read(dest), bit = held & mask != 0
            switch op {
            case .and1: carry = carry && (mode == .c_notmembit ? !bit : bit)
            case .or1: idle(); carry = carry || (mode == .c_notmembit ? !bit : bit)
            case .eor1: idle(); carry = carry != bit
            case .not1: write(dest, held ^ mask)
            default:
                if mode == .membit_c { idle(); write(dest, carry ? held | mask : held & ~mask) }
                else { carry = bit }
            }
        case .clrc: carry = false
        case .setc: carry = true
        case .notc: idle(); carry.toggle()
        case .clrv: flag(0x40, false); flag(8, false)
        case .clrp: flag(0x20, false)
        case .setp: flag(0x20, true)
        case .ei: idle(); flag(4, true)
        case .di: idle(); flag(4, false)
        case .sleep, .stop:
            // Match the corpus's finite observation of the halt bus pattern.
            for _ in 0..<2 { idle(); read(pc) }; idle(); stopped = true
        }
    }
}
