import Carbon

enum MacStaffKeyboardLayout {
    static let keys: [UInt16: StaffKeyboardKey] = {
        let codes: [(Int, StaffKeyboardKey)] = [
            (kVK_ANSI_Grave, .grave), (kVK_ANSI_1, .digit1), (kVK_ANSI_2, .digit2), (kVK_ANSI_3, .digit3),
            (kVK_ANSI_4, .digit4), (kVK_ANSI_5, .digit5), (kVK_ANSI_6, .digit6), (kVK_ANSI_7, .digit7),
            (kVK_ANSI_8, .digit8), (kVK_ANSI_9, .digit9), (kVK_ANSI_0, .digit0), (kVK_ANSI_Minus, .minus),
            (kVK_ANSI_Equal, .equal), (kVK_Delete, .backspace), (kVK_Tab, .tab),
            (kVK_ANSI_Q, .q), (kVK_ANSI_W, .w), (kVK_ANSI_E, .e), (kVK_ANSI_R, .r), (kVK_ANSI_T, .t),
            (kVK_ANSI_Y, .y), (kVK_ANSI_U, .u), (kVK_ANSI_I, .i), (kVK_ANSI_O, .o), (kVK_ANSI_P, .p),
            (kVK_ANSI_LeftBracket, .leftBracket), (kVK_ANSI_RightBracket, .rightBracket), (kVK_ANSI_Backslash, .backslash),
            (kVK_CapsLock, .capsLock), (kVK_ANSI_A, .a), (kVK_ANSI_S, .s), (kVK_ANSI_D, .d), (kVK_ANSI_F, .f),
            (kVK_ANSI_G, .g), (kVK_ANSI_H, .h), (kVK_ANSI_J, .j), (kVK_ANSI_K, .k), (kVK_ANSI_L, .l),
            (kVK_ANSI_Semicolon, .semicolon), (kVK_ANSI_Quote, .quote), (kVK_Return, .returnKey), (kVK_Shift, .leftShift),
            (kVK_ANSI_Z, .z), (kVK_ANSI_X, .x), (kVK_ANSI_C, .c), (kVK_ANSI_V, .v), (kVK_ANSI_B, .b),
            (kVK_ANSI_N, .n), (kVK_ANSI_M, .m), (kVK_ANSI_Comma, .comma), (kVK_ANSI_Period, .period),
            (kVK_ANSI_Slash, .slash), (kVK_RightShift, .rightShift), (kVK_Function, .function),
            (kVK_Control, .leftControl), (kVK_Option, .leftOption), (kVK_Command, .leftCommand), (kVK_Space, .space),
            (kVK_RightCommand, .rightCommand), (kVK_RightOption, .rightOption), (kVK_RightControl, .rightControl)
        ]
        return Dictionary(uniqueKeysWithValues: codes.map { (UInt16($0.0), $0.1) })
    }()
}
