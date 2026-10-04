use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq)]
#[serde(deny_unknown_fields)]
pub struct Coordinate {
    pub lat: f64,
    pub lng: f64,
}

impl Coordinate {
    pub fn valid(self) -> bool {
        self.lat.is_finite()
            && self.lng.is_finite()
            && (-90.0..=90.0).contains(&self.lat)
            && (-180.0..=180.0).contains(&self.lng)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Driver {
    pub id: String,
    pub name: String,
    pub active: bool,
    pub capacity: i32,
    pub location: Option<Coordinate>,
    pub location_updated_at: Option<i64>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Restaurant {
    pub id: String,
    pub name: String,
    pub address: String,
    pub coordinate: Coordinate,
    pub created_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewRestaurant {
    pub name: String,
    pub address: String,
    pub coordinate: Coordinate,
}

impl NewRestaurant {
    pub fn validate(&self) -> Result<(), &'static str> {
        if [&self.name, &self.address]
            .iter()
            .any(|value| value.trim().is_empty() || value.chars().count() > 240)
        {
            return Err("Names and addresses must contain 1–240 characters");
        }
        if !self.coordinate.valid() {
            return Err("Coordinates must be finite latitude/longitude values");
        }
        Ok(())
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum DeliveryStatus {
    Pending,
    Assigned,
    PickedUp,
    Delivered,
}

/// Readiness is independent of assignment and delivery progress. Missing state
/// means the legacy ready_at estimate, never an implicit confirmation of cooking.
#[derive(Debug, Default, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum ReadinessState {
    Unknown,
    #[default]
    Estimated,
    Ready,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Delivery {
    pub id: String,
    pub shop_name: String,
    pub pickup_address: String,
    pub pickup: Coordinate,
    pub dropoff_address: String,
    pub dropoff: Coordinate,
    pub ready_at: i64,
    #[serde(default)]
    pub readiness_state: ReadinessState,
    #[serde(default)]
    pub readiness_revision: u64,
    #[serde(default)]
    pub readiness_updated_at: Option<i64>,
    pub deadline_at: i64,
    pub load_units: i32,
    pub max_ride_seconds: i64,
    pub status: DeliveryStatus,
    pub driver_id: Option<String>,
    pub created_at: i64,
    pub picked_up_at: Option<i64>,
    pub delivered_at: Option<i64>,
    /// Absolute guard captured once on pickup; later routing must not reset it.
    #[serde(default)]
    pub onboard_deadline_at: Option<i64>,
    #[serde(default)]
    pub restaurant_id: Option<String>,
    #[serde(default)]
    pub dispatch_waiting_reason: Option<String>,
}

impl Delivery {
    pub fn readiness_at(&self) -> Option<i64> {
        (self.readiness_state != ReadinessState::Unknown).then_some(self.ready_at)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct NewDelivery {
    pub shop_name: String,
    pub pickup_address: String,
    pub pickup: Coordinate,
    pub dropoff_address: String,
    pub dropoff: Coordinate,
    /// Accepted only for backwards-compatible clients. New clients omit it.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub ready_at: Option<i64>,
    pub deadline_at: i64,
    pub load_units: i32,
    pub max_ride_seconds: i64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub restaurant_id: Option<String>,
}

impl NewDelivery {
    pub fn validate(&self) -> Result<(), &'static str> {
        for value in [&self.shop_name, &self.pickup_address, &self.dropoff_address] {
            if value.trim().is_empty() || value.chars().count() > 240 {
                return Err("Names and addresses must contain 1–240 characters");
            }
        }
        if !self.pickup.valid() || !self.dropoff.valid() {
            return Err("Coordinates must be finite latitude/longitude values");
        }
        // Bounded timestamps make arithmetic safe and reject accidental milliseconds.
        if !(0..=32_503_680_000).contains(&self.deadline_at)
            || self
                .ready_at
                .is_some_and(|at| !(0..=32_503_680_000).contains(&at))
        {
            return Err("Timestamps must be Unix seconds between 1970 and 3000");
        }
        if self.ready_at.is_some_and(|at| self.deadline_at < at) {
            return Err("Deadline must be at or after readiness");
        }
        if !(1..=8).contains(&self.load_units) {
            return Err("Load must be between 1 and 8 units");
        }
        if !(60..=7200).contains(&self.max_ride_seconds) {
            return Err("Maximum ride time must be between 60 and 7200 seconds");
        }
        Ok(())
    }

    pub fn into_delivery(self, now: i64) -> Delivery {
        Delivery {
            id: uuid::Uuid::new_v4().to_string(),
            shop_name: self.shop_name.trim().to_owned(),
            pickup_address: self.pickup_address.trim().to_owned(),
            pickup: self.pickup,
            dropoff_address: self.dropoff_address.trim().to_owned(),
            dropoff: self.dropoff,
            // The legacy numeric field stays decodable by old apps. It has NO
            // readiness meaning while readiness_state=unknown. All new logic
            // must use readiness_at(), not this compatibility projection.
            ready_at: self.ready_at.unwrap_or(now),
            readiness_state: if self.ready_at.is_some() {
                ReadinessState::Estimated
            } else {
                ReadinessState::Unknown
            },
            readiness_revision: 0,
            readiness_updated_at: None,
            deadline_at: self.deadline_at,
            load_units: self.load_units,
            max_ride_seconds: self.max_ride_seconds,
            status: DeliveryStatus::Pending,
            driver_id: None,
            created_at: now,
            picked_up_at: None,
            delivered_at: None,
            onboard_deadline_at: None,
            restaurant_id: self.restaurant_id,
            dispatch_waiting_reason: None,
        }
    }
}

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq, Hash)]
#[serde(rename_all = "snake_case")]
pub enum StopKind {
    Pickup,
    Dropoff,
}

#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq, Hash)]
pub struct StopKey {
    pub delivery_id: String,
    pub kind: StopKind,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteStop {
    pub delivery_id: String,
    pub kind: StopKind,
    pub address: String,
    pub coordinate: Coordinate,
    pub arrival_at: i64,
    pub departure_at: i64,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Route {
    pub driver_id: String,
    pub stops: Vec<RouteStop>,
    pub travel_seconds: i64,
    pub finish_at: i64,
    pub feasible: bool,
    pub warnings: Vec<String>,
    /// Advisory targets do not invalidate otherwise executable routes.
    #[serde(default)]
    pub notices: Vec<String>,
    /// Older clients assume numeric ETAs. New clients must hide them when the
    /// first leg cannot be estimated because no driver position is available.
    #[serde(default = "estimates_available_default")]
    pub estimates_available: bool,
}

fn estimates_available_default() -> bool {
    true
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct Suggestion {
    pub driver_id: String,
    pub incremental_travel_seconds: i64,
    pub route: Route,
}
