// bindgen-flags: --with-derive-hash --with-derive-partialeq --with-derive-eq
//
union foo {
    union {
        unsigned int a;
        unsigned short b;
    } bar;
};
