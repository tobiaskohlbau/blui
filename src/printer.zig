pub const Status = struct {
    pub const Temperature = struct {
        bed: f64,
        bed_target: f64,
        nozzle: f64,
        nozzle_target: f64,
    };

    pub const Fan: type = struct {
        cooling_speed: f64,
        case_speed: f64,
        filter_speed: f64,
    };

    temperature: Temperature,
    fan: Fan,
    print_percent: f64,
    image: []u8,
};
