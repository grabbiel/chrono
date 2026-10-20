# intro — canonical event DSL (one section per object slot)
obj 0 {
  func 0 {
    text greeting
    wait 60
    if MET_LAYLA {
      text shop
    } else {
      set_flag MET_LAYLA
    }
    call overworld#1
    nop
  }
  func 1 {
    text intro
    jump func0
  }
}
