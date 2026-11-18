import { useEffect, useMemo, useState } from "react";
import {
  Activity,
  ArrowDownRight,
  ArrowRight,
  ArrowUpRight,
  Bell,
  CalendarDays,
  Check,
  ChevronDown,
  CircleDollarSign,
  Clock3,
  CreditCard,
  LayoutDashboard,
  Menu,
  MoreHorizontal,
  Plus,
  Search,
  Settings2,
  ShoppingBag,
  Utensils,
  UsersRound,
  Wifi,
  WifiOff,
  X,
} from "lucide-react";
import { QRCodeSVG } from "qrcode.react";
import printedMenu from "../../shared/menu.json";
import { ApiError, apiRequest, getApiBaseUrl, jsonBody, saveApiBaseUrl } from "./api";

type TableStatus = "AVAILABLE" | "OCCUPIED";
type RestaurantTable = {
  number: number;
  status: TableStatus;
  currentBill: { id: string; billNumber: string; amount: string; openedAt: string; itemCount: number } | null;
};
type MenuItemData = {
  id?: string;
  categoryId?: string;
  name: string;
  pricingType: "SINGLE" | "FULL_HALF" | "MANUAL";
  fullPrice: number | string | null;
  halfPrice: number | string | null;
  manualPriceNote?: string;
  active?: boolean;
};
type MenuCategoryData = { id?: string; name: string; sortOrder: number; items: MenuItemData[] };
type RawMenu = typeof printedMenu;
type SignedInUser = { id: string; name: string; username: string; role: "OWNER" | "CASHIER" };
type DashboardData = {
  businessDate: string;
  totalSales: number;
  totalOrders: number;
  availableTables: number;
  occupiedTables: number;
  collections: { CASH: number; UPI: number; CARD: number };
  recentBills: {
    billNumber: string;
    status: "OPEN" | "PAID" | "CANCELLED";
    subtotal: string;
    openedAt: string;
    table: { number: number };
    payments: { method: "CASH" | "UPI" | "CARD" }[];
  }[];
};
type BillLine = {
  id: string;
  itemName: string;
  size: "FULL" | "HALF" | null;
  quantity: number;
  unitPrice: string;
  lineTotal: string;
};
type CurrentBill = {
  id: string;
  billNumber: string;
  status: "OPEN" | "PAID" | "CANCELLED";
  subtotal: string;
  table?: { number: number };
  items: BillLine[];
};

function isMenuPricingType(value: string): value is MenuItemData["pricingType"] {
  return value === "SINGLE" || value === "FULL_HALF" || value === "MANUAL";
}

function parsePrintedMenu(source: RawMenu): MenuCategoryData[] {
  return source.map((category) => ({
    ...category,
    items: category.items.map((item) => {
      if (!isMenuPricingType(item.pricingType)) {
        throw new Error(`Unknown menu pricing type for "${item.name}".`);
      }
      return { ...item, pricingType: item.pricingType };
    }),
  }));
}

const menuCategories = parsePrintedMenu(printedMenu);

function formatCurrency(value: number | string): string {
  return new Intl.NumberFormat("en-IN", {
    style: "currency",
    currency: "INR",
    maximumFractionDigits: 0,
  }).format(Number(value));
}

function App() {
  const [tables, setTables] = useState<RestaurantTable[]>([]);
  const [dashboard, setDashboard] = useState<DashboardData | null>(null);
  const [connection, setConnection] = useState<"connecting" | "connected" | "offline">(
    "connecting",
  );
  const [authToken, setAuthToken] = useState(() => sessionStorage.getItem("kwd-token"));
  const [authUser, setAuthUser] = useState<SignedInUser | null>(null);
  const [authChecking, setAuthChecking] = useState(true);
  const [setupRequired, setSetupRequired] = useState(false);
  const [authError, setAuthError] = useState("");
  const [activeNav, setActiveNav] = useState("Overview");
  const [search, setSearch] = useState("");
  const [mobileNavOpen, setMobileNavOpen] = useState(false);
  const [menuData, setMenuData] = useState<MenuCategoryData[]>(menuCategories);
  const [menuError, setMenuError] = useState("");
  const [menuReload, setMenuReload] = useState(0);
  const [currentBill, setCurrentBill] = useState<CurrentBill | null>(null);
  const [billError, setBillError] = useState("");
  const [busy, setBusy] = useState(false);
  const [notice, setNotice] = useState("");

  function navigateTo(section: string): void {
    setActiveNav(section);
    setMobileNavOpen(false);
  }

  function signOut(): void {
    sessionStorage.removeItem("kwd-token");
    setAuthToken(null);
    setAuthUser(null);
    setTables([]);
    setCurrentBill(null);
    setConnection("offline");
  }

  useEffect(() => {
    let active = true;
    if (!authToken) {
      void apiRequest<{ setupRequired: boolean }>("/auth/setup-status")
        .then((result) => {
          if (active) setSetupRequired(result.setupRequired);
        })
        .catch((error: unknown) => {
          if (active) {
            setAuthError(error instanceof Error ? error.message : "The restaurant server is unavailable.");
          }
        })
        .finally(() => {
          if (active) setAuthChecking(false);
        });
      return () => {
        active = false;
      };
    }

    void apiRequest<SignedInUser>("/me", authToken)
      .then((user) => {
        if (active) {
          setAuthUser(user);
          setAuthError("");
        }
      })
      .catch((error: unknown) => {
        if (active) {
          console.error("Could not restore the signed-in session:", error);
          sessionStorage.removeItem("kwd-token");
          setAuthToken(null);
          setAuthUser(null);
          if (error instanceof ApiError && error.status !== 401) {
            setAuthError(error.message);
          }
        }
      })
      .finally(() => {
        if (active) setAuthChecking(false);
      });

    return () => {
      active = false;
    };
  }, [authToken]);

  useEffect(() => {
    const token = authToken;
    if (!token) return undefined;
    let active = true;
    const controller = new AbortController();

    async function loadTables() {
      if (!token) return;
      try {
        const [result, summary] = await Promise.all([
          apiRequest<RestaurantTable[]>("/tables", token, { signal: controller.signal }),
          apiRequest<DashboardData>("/dashboard", token, { signal: controller.signal }),
        ]);
        if (active) {
          setTables(result);
          setDashboard(summary);
          setConnection("connected");
        }
      } catch (error) {
        if (active && !(error instanceof Error && error.name === "AbortError")) {
          console.error("Unable to load restaurant tables:", error);
          setConnection("offline");
          if (error instanceof ApiError && error.status === 401) signOut();
        }
      }
    }

    void loadTables();
    const intervalId = window.setInterval(() => void loadTables(), 15_000);

    return () => {
      active = false;
      controller.abort();
      window.clearInterval(intervalId);
    };
  }, [authToken]);

  useEffect(() => {
    if (!authToken) return undefined;
    let active = true;
    void apiRequest<MenuCategoryData[]>("/menu", authToken)
      .then((categories) => {
        if (active && categories.length > 0) setMenuData(categories);
      })
      .catch((error: unknown) => {
        if (active) {
          console.error("Could not load the restaurant menu:", error);
          setMenuError(error instanceof Error ? error.message : "Menu is temporarily unavailable.");
        }
      });
    return () => {
      active = false;
    };
  }, [authToken, menuReload]);

  async function onAuthenticated(result: { token: string; user: SignedInUser }): Promise<void> {
    sessionStorage.setItem("kwd-token", result.token);
    setAuthUser(result.user);
    setAuthToken(result.token);
    setAuthError("");
    setSetupRequired(false);
  }

  async function openTableBill(tableNumber: number, existingBillId?: string): Promise<void> {
    if (!authToken) return;
    setBusy(true);
    setBillError("");
    try {
      if (existingBillId) {
        const bill = await apiRequest<CurrentBill>(`/bills/${existingBillId}`, authToken);
        setCurrentBill(bill);
      } else {
        const result = await apiRequest<{ bill: CurrentBill }>(
          "/bills",
          authToken,
          { method: "POST", body: jsonBody({ tableNumber }) },
        );
        setCurrentBill(result.bill);
      }
      navigateTo("Billing");
    } catch (error) {
      console.error("Could not open the table bill:", error);
      setBillError(error instanceof Error ? error.message : "Could not open this table.");
    } finally {
      setBusy(false);
    }
  }

  async function refreshBill(billId: string): Promise<void> {
    if (!authToken) return;
    const bill = await apiRequest<CurrentBill>(`/bills/${billId}`, authToken);
    setCurrentBill(bill);
    const updatedTables = await apiRequest<RestaurantTable[]>("/tables", authToken);
    setTables(updatedTables);
  }

  function reloadMenu(): void {
    setMenuReload((generation) => generation + 1);
  }

  const availableCount = useMemo(
    () => dashboard?.availableTables ?? tables.filter((table) => table.status === "AVAILABLE").length,
    [dashboard, tables],
  );
  const occupiedCount = useMemo(
    () => dashboard?.occupiedTables ?? tables.filter((table) => table.status === "OCCUPIED").length,
    [dashboard, tables],
  );
  const filteredTables = useMemo(() => {
    const query = search.trim();
    if (!query) return tables;
    return tables.filter((table) => String(table.number).includes(query));
  }, [search, tables]);

  if (authChecking) {
    return <LoadingPage message="Connecting to your restaurant workspace..." />;
  }

  if (!authToken || !authUser) {
    return (
      <AuthenticationPage
        setupRequired={setupRequired}
        initialError={authError}
        onAuthenticated={onAuthenticated}
      />
    );
  }

  return (
    <div className="app-shell">
      <aside className={`sidebar${mobileNavOpen ? " mobile-open" : ""}`}>
        <a className="brand" href="#" aria-label="Koli Wada Dhaba home">
          <span className="brand-mark"><Utensils size={21} strokeWidth={2.2} /></span>
          <span className="brand-copy">
            <strong>KOLI WADA</strong>
            <span>FAMILY SEAFOOD RESTAURANT</span>
          </span>
        </a>

        <div className="sidebar-label">WORKSPACE</div>
        <nav className="navigation" aria-label="Main navigation">
          <button
            className={`nav-item ${activeNav === "Overview" ? "active" : ""}`}
            onClick={() => navigateTo("Overview")}
          >
            <LayoutDashboard size={18} /><span>Overview</span>
          </button>
          <button
            className={`nav-item ${activeNav === "Tables" ? "active" : ""}`}
            onClick={() => navigateTo("Tables")}
          >
            <Utensils size={18} /><span>Tables</span><span className="nav-count">70</span>
          </button>
          <button
            className={`nav-item ${activeNav === "Menu" ? "active" : ""}`}
            onClick={() => navigateTo("Menu")}
          >
            <ShoppingBag size={18} /><span>Menu</span><span className="nav-count">{menuCategories.reduce((total, category) => total + category.items.length, 0)}</span>
          </button>
          <button
            className={`nav-item ${activeNav === "Billing" ? "active" : ""}`}
            onClick={() => navigateTo("Billing")}
          >
            <CreditCard size={18} /><span>Billing</span>
          </button>
          <button
            className={`nav-item ${activeNav === "Reports" ? "active" : ""}`}
            onClick={() => navigateTo("Reports")}
          >
            <Activity size={18} /><span>Reports</span>
          </button>
        </nav>

        <div className="sidebar-bottom">
          <div className="shift-card">
            <span className="shift-icon"><Clock3 size={16} /></span>
            <div><strong>Today’s service</strong><span>Ready when you are</span></div>
          </div>
          <button className="nav-item" onClick={() => navigateTo("Settings")}>
            <Settings2 size={18} /><span>Settings</span>
          </button>
          <div className="profile">
            <div className="avatar">KW</div>
            <div className="profile-copy"><strong>{authUser.name}</strong><span>{authUser.role === "OWNER" ? "Owner" : "Cashier"}</span></div>
            <button className="profile-logout" onClick={signOut}>Sign out</button>
          </div>
        </div>
      </aside>
      {mobileNavOpen && (
        <button
          className="mobile-nav-overlay"
          aria-label="Close navigation"
          onClick={() => setMobileNavOpen(false)}
        />
      )}

      <main className="main-content">
        <header className="topbar">
          <div className="breadcrumbs"><span>Workspace</span><span className="crumb-slash">/</span><strong>{activeNav}</strong></div>
          <div className="top-actions">
            <div className={`connection-pill ${connection}`}>
              {connection === "connected" ? <Wifi size={14} /> : <WifiOff size={14} />}
              <span>{connection === "connected" ? "Live connection" : connection === "offline" ? "Service offline" : "Connecting"}</span>
            </div>
            <button className="icon-button notification-button" aria-label="Notifications">
              <Bell size={18} /><span className="notification-dot" />
            </button>
            <div className="top-divider" />
            <button className="date-button"><CalendarDays size={16} /><span>Today</span><ChevronDown size={14} /></button>
          </div>
        </header>

        <div className="page-content">
          {activeNav === "Menu" ? (
            <MenuPage
              categories={menuData}
              error={menuError}
              editable={authUser.role === "OWNER"}
              token={authToken}
              onReload={reloadMenu}
            />
          ) : activeNav === "Tables" ? (
            <TablesPage
              tables={tables}
              connection={connection}
              availableCount={availableCount}
              occupiedCount={occupiedCount}
              search={search}
              onSearchChange={setSearch}
              onSelectTable={openTableBill}
              busy={busy}
            />
          ) : activeNav === "Billing" ? (
            <BillingPage
              bill={currentBill}
              categories={menuData}
              tables={tables}
              connection={connection}
              token={authToken}
              busy={busy}
              error={billError}
              onError={setBillError}
              onOpenTable={(tableNumber, existingBillId) => void openTableBill(tableNumber, existingBillId)}
              onRefreshBill={refreshBill}
              onFinished={(message) => {
                setNotice(message);
                setBillError("");
                setCurrentBill(null);
                setActiveNav("Tables");
                void apiRequest<RestaurantTable[]>("/tables", authToken)
                  .then(setTables)
                  .catch((error: unknown) => console.error("Could not refresh restaurant tables:", error));
              }}
            />
          ) : activeNav === "Settings" ? (
            <SettingsPage token={authToken} user={authUser} />
          ) : activeNav === "Reports" ? (
            <ReportsPage token={authToken} />
          ) : (
            <>
          {notice && <div className="app-alert success-alert">{notice}<button onClick={() => setNotice("")}>Dismiss</button></div>}
          {billError && <div className="app-alert">{billError}<button onClick={() => setBillError("")}>Dismiss</button></div>}
          <section className="welcome-row">
            <div>
              <div className="eyebrow"><span className="eyebrow-line" /> RESTAURANT OVERVIEW</div>
              <h1>Good afternoon<span className="greeting-dot">.</span></h1>
              <p className="welcome-subtitle">Here’s your service at a glance.</p>
            </div>
            <button className="primary-button" onClick={() => navigateTo("Billing")}>
              <Plus size={17} /> New bill
            </button>
          </section>

          <section className="metrics-grid" aria-label="Today's business metrics">
            <MetricCard
              icon={<CircleDollarSign size={19} />}
              iconClass="icon-teal"
              label="TODAY’S SALES"
              value={dashboard ? formatCurrency(dashboard.totalSales) : "—"}
              meta={dashboard ? "Payments recorded today" : "Loading today's payments"}
              trend={<span className="metric-neutral">{dashboard ? "Confirmed payments" : "Waiting for live data"}</span>}
            />
            <MetricCard
              icon={<ShoppingBag size={19} />}
              iconClass="icon-sand"
              label="TOTAL ORDERS"
              value={dashboard ? String(dashboard.totalOrders) : "—"}
              meta={dashboard ? "Bills fully paid today" : "Loading today's orders"}
              trend={<span className="metric-neutral">{dashboard ? "From confirmed payments" : "Waiting for live data"}</span>}
            />
            <MetricCard
              icon={<UsersRound size={19} />}
              iconClass="icon-blue"
              label="AVAILABLE TABLES"
              value={connection === "connected" ? String(availableCount) : "—"}
              meta={connection === "connected" ? "Ready for guests" : "Awaiting live connection"}
              trend={<span className="metric-positive"><ArrowUpRight size={14} /> Available</span>}
            />
            <MetricCard
              icon={<CreditCard size={19} />}
              iconClass="icon-coral"
              label="OCCUPIED TABLES"
              value={connection === "connected" ? String(occupiedCount) : "—"}
              meta={connection === "connected" ? "Currently in service" : "Awaiting live connection"}
              trend={<span className="metric-neutral"><ArrowDownRight size={14} /> In service</span>}
            />
          </section>

          <section className="operations-grid">
            <article className="panel tables-panel">
              <div className="panel-heading">
                <div>
                  <div className="panel-kicker">FLOOR MANAGEMENT</div>
                  <div className="panel-title-row"><h2>Table overview</h2><span className="total-badge">{connection === "connected" ? tables.length : "—"} tables</span></div>
                </div>
                    <button className="subtle-button" onClick={() => navigateTo("Tables")}>View all <ArrowRight size={15} /></button>
              </div>

              <div className="table-toolbar">
                <label className="search-field">
                  <Search size={16} /><input value={search} onChange={(event) => setSearch(event.target.value)} placeholder="Find a table..." />
                </label>
                <div className="table-legend">
                  <span><i className="legend-dot available-dot" />Available</span>
                  <span><i className="legend-dot occupied-dot" />Occupied</span>
                </div>
              </div>

              {connection === "connected" && tables.length > 0 ? (
                <div className="table-grid">
                  {filteredTables.map((table) => (
                    <button
                      className={`table-tile ${table.status.toLowerCase()}`}
                      key={table.number}
                      disabled={busy}
                      onClick={() => void openTableBill(table.number, table.currentBill?.id)}
                      aria-label={`Table ${table.number}, ${table.status === "OCCUPIED" ? "occupied" : "available"}${table.currentBill ? `, bill ${formatCurrency(Number(table.currentBill.amount))}` : ""}`}
                      title={table.currentBill ? `${table.currentBill.billNumber} · ${formatCurrency(Number(table.currentBill.amount))}` : `Table ${table.number} · Available`}
                    >
                      <span className="table-number">{String(table.number).padStart(2, "0")}</span>
                      {table.status === "OCCUPIED" ? (
                        <span className="table-order">{table.currentBill ? formatCurrency(Number(table.currentBill.amount)) : "In service"}</span>
                      ) : <span className="table-order">Available</span>}
                    </button>
                  ))}
                </div>
              ) : (
                <div className="empty-floor">
                  <div className="empty-illustration"><Utensils size={23} /></div>
                  <strong>{connection === "connected" ? "No tables set up yet" : "Table status will appear here"}</strong>
                  <span>{connection === "connected" ? "Connect the database and initialize the 70 restaurant tables." : "Connect the API and database to load live table availability."}</span>
                  {connection === "offline" && <button className="retry-button" onClick={() => window.location.reload()}>Retry connection</button>}
                </div>
              )}

              {connection === "connected" && tables.length > 0 && filteredTables.length === 0 && (
                <div className="search-empty">No tables match “{search}”.</div>
              )}

              <div className="table-panel-footer">
                <span><i className="legend-dot available-dot" />{connection === "connected" ? `${availableCount} available` : "Availability pending"}</span>
                <span><i className="legend-dot occupied-dot" />{connection === "connected" ? `${occupiedCount} occupied` : "Occupancy pending"}</span>
                <span className="refresh-note"><Clock3 size={13} /> Updates every 15 seconds</span>
              </div>
            </article>

            <article className="panel activity-panel">
              <div className="panel-heading">
                <div><div className="panel-kicker">LIVE ACTIVITY</div><div className="panel-title-row"><h2>Recent orders</h2></div></div>
                <button className="icon-button panel-more" aria-label="More order options"><MoreHorizontal size={19} /></button>
              </div>
              {dashboard?.recentBills.length ? <div className="recent-bills-list">{dashboard.recentBills.slice(0, 5).map((recent) => <button className="recent-bill-row" key={recent.billNumber} onClick={() => navigateTo("Reports")}><span className="recent-bill-icon"><ShoppingBag size={14} /></span><span className="recent-bill-info"><strong>{recent.billNumber}</strong><small>Table {recent.table.number} · {recent.status}</small></span><strong className="recent-bill-amount">{formatCurrency(recent.subtotal)}</strong></button>)}</div> : (
                <div className="activity-empty">
                  <div className="activity-icon"><ShoppingBag size={19} /></div>
                  <strong>{dashboard ? "No orders yet" : "Waiting for restaurant data"}</strong>
                  <span>{dashboard ? <>Once your team starts a bill,<br />recent activity will show up here.</> : <>Connect the database to<br />view recent bills.</>}</span>
                </div>
              )}
              <button className="activity-link" onClick={() => navigateTo("Reports")}>See all activity <ArrowRight size={15} /></button>
            </article>
          </section>

          <section className="bottom-grid">
            <article className="panel collection-panel">
              <div className="panel-heading">
                <div><div className="panel-kicker">PAYMENT BREAKDOWN</div><div className="panel-title-row"><h2>Today’s collection</h2></div></div>
                <button className="period-button">Today <ChevronDown size={14} /></button>
              </div>
              <div className={`collection-chart ${dashboard && dashboard.totalSales > 0 ? "" : "collection-no-data"}`}>
                {dashboard && dashboard.totalSales > 0 ? (["CASH", "UPI", "CARD"] as const).map((method) => {
                  const percentage = Math.max(5, dashboard.totalSales ? (dashboard.collections[method] / dashboard.totalSales) * 100 : 0);
                  return <div className="collection-bar-column" key={method}><span>{formatCurrency(dashboard.collections[method])}</span><i className={`collection-bar ${method.toLowerCase()}`} style={{ height: `${percentage}%` }} /><small>{method}</small></div>;
                }) : <p>{dashboard ? "No completed payments recorded today." : "Collection details will appear when the database is connected."}</p>}
              </div>
              <div className="collection-legend">
                <span><i className="legend-dot cash-dot" />Cash <b>{dashboard ? formatCurrency(dashboard.collections.CASH) : "—"}</b></span>
                <span><i className="legend-dot upi-dot" />UPI <b>{dashboard ? formatCurrency(dashboard.collections.UPI) : "—"}</b></span>
                <span><i className="legend-dot card-dot" />Card <b>{dashboard ? formatCurrency(dashboard.collections.CARD) : "—"}</b></span>
              </div>
            </article>

            <article className="panel getting-started-panel">
              <div className="setup-icon"><Check size={18} /></div>
              <div className="setup-content">
                <div className="panel-kicker">YOUR WORKSPACE</div>
                <h2>One step at a time.</h2>
                <p>The restaurant dashboard is ready. Start PostgreSQL and seed the menu to bring tables online, then use billing, reports, and settings to run service.</p>
                <button className="setup-link" onClick={() => navigateTo("Tables")}>Explore table setup <ArrowRight size={15} /></button>
              </div>
              <div className="setup-decoration"><span /><span /><span /></div>
            </article>
          </section>
          <footer className="page-footer"><span>KOLI WADA DHABA <b>·</b> Family Seafood Restaurant</span><span>Restaurant operations <b>·</b> {new Date().getFullYear()}</span></footer>
            </>
          )}
        </div>
      </main>
      <button
        className="mobile-menu"
        aria-label={mobileNavOpen ? "Close menu" : "Open menu"}
        aria-expanded={mobileNavOpen}
        onClick={() => setMobileNavOpen((open) => !open)}
      >
        {mobileNavOpen ? <X size={21} /> : <Menu size={21} />}
      </button>
    </div>
  );
}

function LoadingPage({ message }: { message: string }) {
  return (
    <main className="auth-page">
      <section className="auth-card loading-card">
        <span className="brand-mark"><Utensils size={22} /></span>
        <strong>KOLI WADA DHABA</strong>
        <span>{message}</span>
      </section>
    </main>
  );
}

function AuthenticationPage({
  setupRequired,
  initialError,
  onAuthenticated,
}: {
  setupRequired: boolean;
  initialError: string;
  onAuthenticated: (result: { token: string; user: SignedInUser }) => Promise<void>;
}) {
  const [name, setName] = useState("");
  const [username, setUsername] = useState("");
  const [email, setEmail] = useState("");
  const [password, setPassword] = useState("");
  const [recoveryCode, setRecoveryCode] = useState("");
  const [error, setError] = useState(initialError);
  const [notice, setNotice] = useState("");
  const [busy, setBusy] = useState(false);
  const [authMode, setAuthMode] = useState<"login" | "request-reset" | "confirm-reset">("login");
  const [editingServer, setEditingServer] = useState(false);
  const [serverAddress, setServerAddress] = useState(getApiBaseUrl() || window.location.origin);

  useEffect(() => setError(initialError), [initialError]);

  async function submit(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setBusy(true);
    setError("");
    setNotice("");
    try {
      if (!setupRequired && authMode === "request-reset") {
        const result = await apiRequest<{ message: string }>("/auth/password-reset/request", undefined, {
          method: "POST",
          body: jsonBody({ username, email }),
        });
        setNotice(result.message);
        setAuthMode("confirm-reset");
        return;
      }

      if (!setupRequired && authMode === "confirm-reset") {
        const result = await apiRequest<{ message: string }>("/auth/password-reset/confirm", undefined, {
          method: "POST",
          body: jsonBody({ username, email, code: recoveryCode, password }),
        });
        setNotice(result.message);
        setAuthMode("login");
        setRecoveryCode("");
        setPassword("");
        return;
      }

      const result = await apiRequest<{ token: string; user: SignedInUser }>(
        setupRequired ? "/auth/setup" : "/auth/login",
        undefined,
        {
          method: "POST",
          body: jsonBody(
            setupRequired
              ? { name, username, email, password }
              : { username, password },
          ),
        },
      );
      await onAuthenticated(result);
    } catch (requestError) {
      console.error("Could not sign in:", requestError);
      setError(requestError instanceof Error ? requestError.message : "Sign-in failed.");
    } finally {
      setBusy(false);
    }
  }

  return (
    <main className="auth-page">
      <section className="auth-card">
        <span className="brand-mark auth-brand-mark"><Utensils size={22} /></span>
        <div className="auth-brand">KOLI WADA DHABA</div>
        <div className="auth-subbrand">FAMILY SEAFOOD RESTAURANT</div>
        <div className="auth-rule" />
        <p className="panel-kicker">{setupRequired ? "FIRST-TIME SETUP" : authMode === "login" ? "SECURE RESTAURANT ACCESS" : "ACCOUNT RECOVERY"}</p>
        <h1>
          {setupRequired
            ? "Set up your owner account."
            : authMode === "login"
              ? "Welcome back."
              : authMode === "request-reset"
                ? "Forgot your password?"
                : "Enter your recovery code."}
        </h1>
        <p className="auth-description">
          {setupRequired
            ? "Create the first owner login and add an email for password recovery."
            : authMode === "login"
              ? "Sign in with the username and password provided by your restaurant owner."
              : authMode === "request-reset"
                ? "Enter the Owner username and registered recovery email. We will send an 8-digit code."
                : "Check the recovery email for the 8-digit code. It expires in 15 minutes."}
        </p>
        {error && <div className="app-alert auth-alert">{error}</div>}
        {notice && <div className="auth-notice" role="status">{notice}</div>}
        <form className="auth-form" onSubmit={(event) => void submit(event)}>
          {setupRequired && (
            <label>
              <span>Owner name</span>
              <input autoComplete="name" value={name} onChange={(event) => setName(event.target.value)} minLength={2} maxLength={80} required />
            </label>
          )}
          <label>
            <span>Username</span>
            <input autoComplete="username" value={username} onChange={(event) => setUsername(event.target.value)} minLength={3} maxLength={40} pattern="[A-Za-z0-9._-]+" required />
          </label>
          {(setupRequired || authMode !== "login") && (
            <label>
              <span>Recovery email</span>
              <input type="email" autoComplete="email" value={email} onChange={(event) => setEmail(event.target.value)} maxLength={254} required />
            </label>
          )}
          {authMode === "confirm-reset" && (
            <label>
              <span>8-digit email code</span>
              <input inputMode="numeric" autoComplete="one-time-code" value={recoveryCode} onChange={(event) => setRecoveryCode(event.target.value.replace(/\D/g, "").slice(0, 8))} pattern="[0-9]{8}" minLength={8} maxLength={8} required />
            </label>
          )}
          {(setupRequired || authMode !== "request-reset") && (
            <label>
              <span>{authMode === "confirm-reset" ? "New password" : "Password"}</span>
              <input type="password" autoComplete={setupRequired || authMode === "confirm-reset" ? "new-password" : "current-password"} value={password} onChange={(event) => setPassword(event.target.value)} minLength={12} maxLength={128} required />
            </label>
          )}
          {(setupRequired || authMode === "confirm-reset") && <span className="auth-help">Use at least 12 characters. Passwords are stored as salted, one-way hashes.</span>}
          <button className="primary-button auth-submit" disabled={busy}>
            {busy ? "Please wait..." : setupRequired ? "Create owner account" : authMode === "login" ? "Sign in" : authMode === "request-reset" ? "Email recovery code" : "Change password"}
          </button>
        </form>
        {!setupRequired && authMode === "login" && (
          <button className="auth-link" type="button" onClick={() => { setError(""); setNotice(""); setAuthMode("request-reset"); }}>
            Forgot password?
          </button>
        )}
        {!setupRequired && authMode !== "login" && (
          <button className="auth-link" type="button" onClick={() => { setError(""); setNotice(""); setAuthMode("login"); }}>
            Back to sign in
          </button>
        )}
        {editingServer ? (
          <form className="server-address-form" onSubmit={(event) => {
            event.preventDefault();
            try {
              saveApiBaseUrl(serverAddress);
              window.location.reload();
            } catch (requestError) {
              setError(requestError instanceof Error ? requestError.message : "Server address is invalid.");
            }
          }}>
            <label>
              <span>Restaurant server HTTPS address</span>
              <input type="url" value={serverAddress} onChange={(event) => setServerAddress(event.target.value)} placeholder="https://your-server.example" required />
            </label>
            <button type="submit" className="auth-link">Save server address</button>
          </form>
        ) : (
          <button className="auth-link server-address-link" type="button" onClick={() => setEditingServer(true)}>
            Change server address
          </button>
        )}
        <footer className="auth-footer">Your restaurant data stays with your configured backend.</footer>
      </section>
    </main>
  );
}

function MenuPage({
  categories,
  error,
  editable,
  token,
  onReload,
}: {
  categories: MenuCategoryData[];
  error: string;
  editable: boolean;
  token: string;
  onReload: () => void;
}) {
  const [selectedCategory, setSelectedCategory] = useState(categories[0]?.name ?? "");
  const [search, setSearch] = useState("");
  const [editingItem, setEditingItem] = useState<MenuItemData | null>(null);
  const [creatingItem, setCreatingItem] = useState(false);
  const [editName, setEditName] = useState("");
  const [editCategoryId, setEditCategoryId] = useState("");
  const [editPricingType, setEditPricingType] = useState<MenuItemData["pricingType"]>("SINGLE");
  const [editFullPrice, setEditFullPrice] = useState("");
  const [editHalfPrice, setEditHalfPrice] = useState("");
  const [newCategoryName, setNewCategoryName] = useState("");
  const [saving, setSaving] = useState(false);
  const [editError, setEditError] = useState("");
  const visibleCategories = categories.filter((category) => {
    if (!search.trim()) return category.name === selectedCategory;
    return (
      category.name.toLowerCase().includes(search.trim().toLowerCase()) ||
      category.items.some((item) => item.name.toLowerCase().includes(search.trim().toLowerCase()))
    );
  });
  const totalItems = categories.reduce((total, category) => total + category.items.length, 0);

  function startEditing(item: MenuItemData) {
    setEditingItem(item);
    setCreatingItem(false);
    setEditName(item.name);
    setEditCategoryId(item.categoryId ?? "");
    setEditPricingType(item.pricingType);
    setEditFullPrice(item.fullPrice?.toString() ?? "");
    setEditHalfPrice(item.halfPrice?.toString() ?? "");
    setEditError("");
  }

  function startCreatingItem(categoryId = categories[0]?.id ?? "") {
    setEditingItem({ name: "", pricingType: "SINGLE", fullPrice: null, halfPrice: null });
    setCreatingItem(true);
    setEditName("");
    setEditCategoryId(categoryId);
    setEditPricingType("SINGLE");
    setEditFullPrice("");
    setEditHalfPrice("");
    setEditError("");
  }

  async function addCategory(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setEditError("");
    try {
      await apiRequest("/menu/categories", token, {
        method: "POST",
        body: jsonBody({ name: newCategoryName, sortOrder: categories.length * 10 }),
      });
      setSelectedCategory(newCategoryName);
      setNewCategoryName("");
      onReload();
    } catch (saveError) {
      console.error("Could not add menu category:", saveError);
      setEditError(saveError instanceof Error ? saveError.message : "Could not add this category.");
    } finally {
      setSaving(false);
    }
  }

  async function saveItem(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!editingItem) return;
    const fullPrice = editPricingType === "MANUAL" ? null : editFullPrice.trim() || null;
    const halfPrice = editPricingType === "FULL_HALF" ? editHalfPrice.trim() || null : null;
    if (
      (editPricingType === "SINGLE" && (!fullPrice || halfPrice)) ||
      (editPricingType === "FULL_HALF" && !fullPrice) ||
      (editPricingType === "MANUAL" && (fullPrice || halfPrice))
    ) {
      setEditError("Enter prices that match the selected pricing type.");
      return;
    }

    setSaving(true);
    setEditError("");
    try {
      await apiRequest(
        creatingItem ? "/menu/items" : `/menu/items/${editingItem.id}`,
        token,
        {
          method: creatingItem ? "POST" : "PATCH",
          body: jsonBody({
            name: editName,
            categoryId: editCategoryId,
            pricingType: editPricingType,
            fullPrice,
            halfPrice,
          }),
        },
      );
      setEditingItem(null);
      setCreatingItem(false);
      onReload();
    } catch (saveError) {
      console.error("Could not save menu item:", saveError);
      setEditError(saveError instanceof Error ? saveError.message : "Could not save this menu item.");
    } finally {
      setSaving(false);
    }
  }

  async function setItemActive(item: MenuItemData) {
    if (!item.id) return;
    setSaving(true);
    setEditError("");
    try {
      await apiRequest(`/menu/items/${item.id}`, token, {
        method: "PATCH",
        body: jsonBody({ active: item.active === false }),
      });
      onReload();
    } catch (saveError) {
      console.error("Could not change menu item availability:", saveError);
      setEditError(saveError instanceof Error ? saveError.message : "Could not change menu item availability.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <section className="menu-welcome">
        <div>
          <div className="eyebrow"><span className="eyebrow-line" /> FROM YOUR ORIGINAL MENU CARDS</div>
          <h1>Restaurant menu<span className="greeting-dot">.</span></h1>
          <p className="welcome-subtitle">{categories.length} categories · {totalItems} transcribed items</p>
        </div>
        <div className="menu-title-actions"><div className="transcription-badge"><Check size={14} /> Prices transcribed from menu cards</div>{editable && <><span className="owner-badge">Owner menu controls</span><button className="primary-button" disabled={saving || categories.length === 0} onClick={() => startCreatingItem()}>Add menu item</button></>}</div>
      </section>

      {editable && <form className="menu-add-category-form" onSubmit={(event) => void addCategory(event)}><label>New menu category<input value={newCategoryName} onChange={(event) => setNewCategoryName(event.target.value)} minLength={2} maxLength={80} required placeholder="Category name" /></label><button className="subtle-button" disabled={saving}>Add category</button></form>}
      <label className="menu-search">
        <Search size={17} />
        <input
          value={search}
          onChange={(event) => setSearch(event.target.value)}
          placeholder="Search dishes or categories..."
        />
        {search && <button onClick={() => setSearch("")} type="button">Clear</button>}
      </label>
      {error && <div className="app-alert">{error}</div>}
      {editError && <div className="app-alert">{editError}<button onClick={() => setEditError("")}>Dismiss</button></div>}

      <div className="menu-layout">
        <nav className="menu-categories" aria-label="Menu categories">
          {categories.map((category) => (
            <button
              className={`menu-category ${!search && selectedCategory === category.name ? "selected" : ""}`}
              key={category.name}
              onClick={() => {
                setSelectedCategory(category.name);
                setSearch("");
              }}
            >
              <span>{category.name}</span><small>{category.items.length}</small>
            </button>
          ))}
        </nav>

        <div className="menu-items">
          {visibleCategories.length === 0 ? (
            <div className="menu-no-results"><Search size={21} /><strong>No matching dishes</strong><span>Try a different search.</span></div>
          ) : visibleCategories.map((category) => (
            <section className="menu-category-panel" key={category.name}>
              <div className="menu-panel-heading">
                <div><div className="panel-kicker">MENU CATEGORY</div><h2>{category.name}</h2></div>
                <div className="panel-title-row"><span className="total-badge">{category.items.filter((item) => !search || item.name.toLowerCase().includes(search.trim().toLowerCase())).length} items</span>{editable && category.id && <button className="subtle-button" onClick={() => startCreatingItem(category.id)}>Add item</button>}</div>
              </div>
              <div className="menu-item-list">
                {category.items.filter((item) => !search || item.name.toLowerCase().includes(search.trim().toLowerCase())).map((item) => (
                  <article className="menu-item" key={item.name}>
                    <div className="dish-marker"><Utensils size={14} /></div>
                    <div className="dish-name">
                      <strong>{item.name}</strong>
                      {item.pricingType === "MANUAL" && <span>{item.manualPriceNote ?? "Price to be entered manually"}</span>}
                    </div>
                    <div className="dish-prices">
                      {item.pricingType === "FULL_HALF" ? (
                        <>
                          <span><small>FULL</small><strong>{item.fullPrice === null ? "Enter price" : formatCurrency(item.fullPrice)}</strong></span>
                          <span><small>HALF</small><strong>{item.halfPrice === null ? "Not listed" : formatCurrency(item.halfPrice)}</strong></span>
                        </>
                      ) : item.pricingType === "MANUAL" ? (
                        <span><small>PRICE</small><strong>Manual</strong></span>
                      ) : (
                        <span><small>PRICE</small><strong>{item.fullPrice === null ? "Enter price" : formatCurrency(item.fullPrice)}</strong></span>
                      )}
                    </div>
                    {editable && item.id && <div className="menu-item-actions"><button onClick={() => startEditing(item)}>Edit</button><button disabled={saving} onClick={() => void setItemActive(item)}>{item.active === false ? "Enable" : "Disable"}</button></div>}
                  </article>
                ))}
              </div>
            </section>
          ))}
          <p className="menu-price-note">A dash on the printed menu is shown as “Not listed.” Missing or size-based prices must be entered manually; no prices have been estimated.</p>
        </div>
      </div>
      <footer className="page-footer"><span>KOLI WADA DHABA <b>·</b> Family Seafood Restaurant</span><span>Source: supplied restaurant menu-card photographs</span></footer>
      {editingItem && (
        <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !saving) setEditingItem(null); }}>
          <section className="dialog-card" role="dialog" aria-modal="true" aria-labelledby="edit-menu-heading">
            <div className="panel-heading"><div><div className="panel-kicker">OWNER MENU MANAGEMENT</div><h2 id="edit-menu-heading">{creatingItem ? "Add menu item" : "Edit menu item"}</h2></div><button className="icon-button" disabled={saving} aria-label="Close dialog" onClick={() => { setEditingItem(null); setCreatingItem(false); }}><X size={20} /></button></div>
            <form className="dialog-form" onSubmit={(event) => void saveItem(event)}>
              <label>Item name<input value={editName} onChange={(event) => setEditName(event.target.value)} maxLength={120} required /></label>
              <label>Category<select value={editCategoryId} onChange={(event) => setEditCategoryId(event.target.value)} required>{categories.filter((category) => category.id).map((category) => <option value={category.id} key={category.id}>{category.name}</option>)}</select></label>
              <label>Pricing type<select value={editPricingType} onChange={(event) => setEditPricingType(event.target.value as MenuItemData["pricingType"])}><option value="SINGLE">Single price</option><option value="FULL_HALF">Full / Half</option><option value="MANUAL">Manual price</option></select></label>
              <div className="dialog-fields"><label>Full / single price (₹)<input type="number" min="0.01" step="0.01" disabled={editPricingType === "MANUAL"} required={editPricingType !== "MANUAL"} value={editFullPrice} onChange={(event) => setEditFullPrice(event.target.value)} /></label><label>Half price (₹)<input type="number" min="0.01" step="0.01" disabled={editPricingType !== "FULL_HALF"} value={editHalfPrice} onChange={(event) => setEditHalfPrice(event.target.value)} /></label></div>
              <p className="menu-price-note">Changing menu prices will not change previously issued bills. Previously unlisted prices remain empty until confirmed.</p>
              <button className="primary-button auth-submit" disabled={saving}>{saving ? "Saving..." : creatingItem ? "Add menu item" : "Save menu item"}</button>
            </form>
          </section>
        </div>
      )}
    </>
  );
}

type RestaurantSettings = {
  restaurantName: string;
  subtitle: string;
  upiId: string | null;
  upiPayeeName: string | null;
  receiptWidthMm: 58 | 80;
};
type StaffUser = {
  id: string;
  name: string;
  username: string;
  role: "OWNER" | "CASHIER";
  active: boolean;
  createdAt: string;
};
type DailyReport = {
  businessDate: string;
  payments: { method: "CASH" | "UPI" | "CARD"; amount: number; count: number }[];
  paidBills: { billNumber: string; subtotal: string; closedAt: string | null }[];
  cancelledBills: { billNumber: string; subtotal: string; closedAt: string | null }[];
  tableSales: { tableNumber: number | null; amount: string; orders: number }[];
};
type ReceiptBill = {
  id: string;
  billNumber: string;
  status: "OPEN" | "PAID" | "CANCELLED";
  subtotal: string;
  openedAt: string;
  closedAt: string | null;
  table: { number: number };
  payments: { method: "CASH" | "UPI" | "CARD"; amount: string; confirmedAt: string }[];
  items: BillLine[];
};

function SettingsPage({ token, user }: { token: string; user: SignedInUser }) {
  const [settings, setSettings] = useState<RestaurantSettings>({
    restaurantName: "KOLI WADA DHABA",
    subtitle: "Family Seafood Restaurant",
    upiId: "",
    upiPayeeName: "",
    receiptWidthMm: 80,
  });
  const [users, setUsers] = useState<StaffUser[]>([]);
  const [error, setError] = useState("");
  const [notice, setNotice] = useState("");
  const [saving, setSaving] = useState(false);
  const [staffName, setStaffName] = useState("");
  const [staffUsername, setStaffUsername] = useState("");
  const [staffPassword, setStaffPassword] = useState("");

  async function loadSettingsAndUsers(): Promise<void> {
    const savedSettings = await apiRequest<RestaurantSettings>("/settings", token);
    setSettings(savedSettings);
    if (user.role === "OWNER") {
      setUsers(await apiRequest<StaffUser[]>("/users", token));
    }
  }

  useEffect(() => {
    let active = true;
    void Promise.all([
      apiRequest<RestaurantSettings>("/settings", token),
      user.role === "OWNER" ? apiRequest<StaffUser[]>("/users", token) : Promise.resolve([]),
    ])
      .then(([savedSettings, savedUsers]) => {
        if (active) {
          setSettings(savedSettings);
          setUsers(savedUsers);
        }
      })
      .catch((loadError: unknown) => {
        console.error("Could not load restaurant settings:", loadError);
        if (active) setError(loadError instanceof Error ? loadError.message : "Restaurant settings are unavailable.");
      });
    return () => {
      active = false;
    };
  }, [token, user.role]);

  async function saveSettings(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setError("");
    setNotice("");
    try {
      const saved = await apiRequest<RestaurantSettings>("/settings", token, {
        method: "PATCH",
        body: jsonBody(settings),
      });
      setSettings(saved);
      setNotice("Restaurant settings saved.");
    } catch (saveError) {
      console.error("Could not save restaurant settings:", saveError);
      setError(saveError instanceof Error ? saveError.message : "Could not save restaurant settings.");
    } finally {
      setSaving(false);
    }
  }

  async function addCashier(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSaving(true);
    setError("");
    try {
      await apiRequest("/users", token, {
        method: "POST",
        body: jsonBody({
          name: staffName,
          username: staffUsername,
          password: staffPassword,
          role: "CASHIER",
        }),
      });
      setStaffName("");
      setStaffUsername("");
      setStaffPassword("");
      await loadSettingsAndUsers();
      setNotice("Cashier account created.");
    } catch (saveError) {
      console.error("Could not create cashier account:", saveError);
      setError(saveError instanceof Error ? saveError.message : "Could not create cashier account.");
    } finally {
      setSaving(false);
    }
  }

  async function toggleUserActive(staff: StaffUser) {
    setSaving(true);
    setError("");
    try {
      await apiRequest(`/users/${staff.id}`, token, {
        method: "PATCH",
        body: jsonBody({ active: !staff.active }),
      });
      setUsers(await apiRequest<StaffUser[]>("/users", token));
    } catch (saveError) {
      console.error("Could not update staff account:", saveError);
      setError(saveError instanceof Error ? saveError.message : "Could not update this account.");
    } finally {
      setSaving(false);
    }
  }

  return (
    <>
      <section className="welcome-row">
        <div><div className="eyebrow"><span className="eyebrow-line" /> RESTAURANT CONFIGURATION</div><h1>Settings<span className="greeting-dot">.</span></h1><p className="welcome-subtitle">Configure official restaurant and printer settings.</p></div>
      </section>
      {error && <div className="app-alert">{error}<button onClick={() => setError("")}>Dismiss</button></div>}
      {notice && <div className="app-alert success-alert">{notice}<button onClick={() => setNotice("")}>Dismiss</button></div>}
      {user.role !== "OWNER" ? (
        <section className="panel settings-panel"><strong>Owner access required</strong><p>Only the restaurant owner can change UPI details and manage staff accounts.</p></section>
      ) : (
        <>
          <section className="panel settings-panel">
            <div className="panel-heading"><div><div className="panel-kicker">RECEIPTS &amp; PAYMENTS</div><div className="panel-title-row"><h2>Restaurant settings</h2></div></div></div>
            <form className="settings-form" onSubmit={(event) => void saveSettings(event)}>
              <label>Restaurant name<input value={settings.restaurantName} maxLength={80} onChange={(event) => setSettings({ ...settings, restaurantName: event.target.value })} required /></label>
              <label>Restaurant subtitle<input value={settings.subtitle} maxLength={100} onChange={(event) => setSettings({ ...settings, subtitle: event.target.value })} /></label>
              <label>UPI ID<input value={settings.upiId ?? ""} maxLength={120} placeholder="restaurant@bank" onChange={(event) => setSettings({ ...settings, upiId: event.target.value })} /></label>
              <label>UPI payee name<input value={settings.upiPayeeName ?? ""} maxLength={80} placeholder="Name verified in UPI app" onChange={(event) => setSettings({ ...settings, upiPayeeName: event.target.value })} /></label>
              <label className="receipt-width-setting">Thermal paper width<select value={settings.receiptWidthMm} onChange={(event) => setSettings({ ...settings, receiptWidthMm: Number(event.target.value) as 58 | 80 })}><option value={58}>58 mm</option><option value={80}>80 mm</option></select></label>
              <button className="primary-button auth-submit" disabled={saving}>{saving ? "Saving..." : "Save settings"}</button>
            </form>
            <p className="menu-price-note">UPI payments are cashier-confirmed. Setting an ID does not verify a payment. Actual printer connectivity still needs testing with your printer model.</p>
          </section>

          <section className="panel settings-panel staff-panel">
            <div className="panel-heading"><div><div className="panel-kicker">STAFF ACCESS</div><div className="panel-title-row"><h2>Restaurant users</h2><span className="total-badge">{users.length}</span></div></div></div>
            <form className="settings-form staff-create-form" onSubmit={(event) => void addCashier(event)}>
              <label>Cashier name<input value={staffName} onChange={(event) => setStaffName(event.target.value)} minLength={2} maxLength={80} required /></label>
              <label>Username<input value={staffUsername} onChange={(event) => setStaffUsername(event.target.value)} minLength={3} maxLength={40} pattern="[A-Za-z0-9._-]+" required /></label>
              <label>Temporary password<input type="password" autoComplete="new-password" value={staffPassword} onChange={(event) => setStaffPassword(event.target.value)} minLength={12} maxLength={128} required /><small>At least 12 characters. Share privately with your cashier.</small></label>
              <button className="primary-button auth-submit" disabled={saving}>Create cashier account</button>
            </form>
            <div className="staff-list">{users.map((staff) => <article className="staff-row" key={staff.id}><div className="avatar">{staff.name.slice(0, 2).toUpperCase()}</div><div className="staff-info"><strong>{staff.name}</strong><span>{staff.username} · {staff.role}</span></div><span className={`staff-state ${staff.active ? "enabled" : "inactive"}`}>{staff.active ? "Active" : "Inactive"}</span><button className="subtle-button" disabled={saving || staff.id === user.id} onClick={() => void toggleUserActive(staff)}>{staff.active ? "Disable" : "Enable"}</button></article>)}</div>
          </section>
        </>
      )}
    </>
  );
}

function ReportsPage({ token }: { token: string }) {
  const [date, setDate] = useState(() => new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(new Date()));
  const [report, setReport] = useState<DailyReport | null>(null);
  const [bills, setBills] = useState<ReceiptBill[]>([]);
  const [cancelledBills, setCancelledBills] = useState<ReceiptBill[]>([]);
  const [settings, setSettings] = useState<RestaurantSettings | null>(null);
  const [receipt, setReceipt] = useState<ReceiptBill | null>(null);
  const [printMode, setPrintMode] = useState<"report" | "receipt" | null>(null);
  const [error, setError] = useState("");

  useEffect(() => {
    let active = true;
    void Promise.all([
      apiRequest<DailyReport>(`/reports/daily?date=${encodeURIComponent(date)}`, token),
      apiRequest<ReceiptBill[]>("/bills?status=PAID", token),
      apiRequest<ReceiptBill[]>("/bills?status=CANCELLED", token),
      apiRequest<RestaurantSettings>("/settings", token),
    ])
      .then(([daily, history, cancelled, savedSettings]) => {
        if (active) {
          setReport(daily);
          setBills(history);
          setCancelledBills(cancelled);
          setSettings(savedSettings);
        }
      })
      .catch((reportError: unknown) => {
        console.error("Could not load restaurant reports:", reportError);
        if (active) setError(reportError instanceof Error ? reportError.message : "Reports are temporarily unavailable.");
      });
    return () => {
      active = false;
    };
  }, [date, token]);

  useEffect(() => {
    if (!printMode) return undefined;
    const resetPrintMode = () => setPrintMode(null);
    window.addEventListener("afterprint", resetPrintMode);
    return () => window.removeEventListener("afterprint", resetPrintMode);
  }, [printMode]);

  const collections = { CASH: 0, UPI: 0, CARD: 0 };
  for (const payment of report?.payments ?? []) collections[payment.method] = payment.amount;
  const paidBillCount = report?.paidBills.length ?? 0;
  const totalSales = collections.CASH + collections.UPI + collections.CARD;
  const todaysBills = bills.filter((bill) => bill.closedAt && new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(new Date(bill.closedAt)) === date);
  const todaysCancelledBills = cancelledBills.filter((bill) => bill.closedAt && new Intl.DateTimeFormat("en-CA", { timeZone: "Asia/Kolkata" }).format(new Date(bill.closedAt)) === date);

  function downloadCsv() {
    if (!report) return;
    const rows = [
      ["Report", "Daily restaurant sales", report.businessDate],
      ["Payment method", "Collection (INR)", "Payments"],
      ...report.payments.map((payment) => [payment.method, payment.amount.toFixed(2), String(payment.count)]),
      [],
      ["Bill number", "Status", "Table", "Total (INR)", "Closed at"],
      ...[
        ...report.paidBills.map((bill) => ({ ...bill, status: "PAID" })),
        ...report.cancelledBills.map((bill) => ({ ...bill, status: "CANCELLED" })),
      ].map((bill) => [
        bill.billNumber,
        bill.status,
        String(todaysBills.find((entry) => entry.billNumber === bill.billNumber)?.table.number ?? ""),
        bill.subtotal,
        bill.closedAt ?? "",
      ]),
    ];
    const csv = rows.map((row) => row.map((field) => `"${String(field ?? "").replaceAll('"', '""')}"`).join(",")).join("\r\n");
    const blob = new Blob(["\uFEFF", csv], { type: "text/csv;charset=utf-8" });
    const url = URL.createObjectURL(blob);
    const link = document.createElement("a");
    link.href = url;
    link.download = `koli-wada-dhaba-${report.businessDate}.csv`;
    link.click();
    URL.revokeObjectURL(url);
  }

  async function viewReceipt(bill: ReceiptBill) {
    try {
      setReceipt(await apiRequest<ReceiptBill>(`/bills/${bill.id}`, token));
      setPrintMode("receipt");
      window.setTimeout(() => window.print(), 100);
    } catch (receiptError) {
      console.error("Could not retrieve the bill for printing:", receiptError);
      setError(receiptError instanceof Error ? receiptError.message : "Could not open this receipt.");
    }
  }

  return (
    <div className={`report-page-wrap ${printMode ? `print-${printMode}` : ""}`}>
      <section className="welcome-row"><div><div className="eyebrow"><span className="eyebrow-line" /> BUSINESS REPORTS</div><h1>Sales and bill history<span className="greeting-dot">.</span></h1><p className="welcome-subtitle">Recorded payments and closed bills. No estimated sales.</p></div><button className="primary-button" disabled={!report} onClick={downloadCsv}>Export CSV</button></section>
      {error && <div className="app-alert">{error}<button onClick={() => setError("")}>Dismiss</button></div>}
      <section className="panel report-panel">
        <div className="panel-heading"><div><div className="panel-kicker">DAILY SALES REPORT</div><div className="panel-title-row"><h2>Collection summary</h2></div></div><label className="report-date">Business date<input type="date" value={date} onChange={(event) => setDate(event.target.value)} /></label></div>
        <div className="report-total-card"><span>Completed sales</span><strong>{formatCurrency(totalSales)}</strong><small>{paidBillCount} fully paid bills · {date}</small></div>
        <div className="report-payment-grid">{(["CASH", "UPI", "CARD"] as const).map((method) => <article className="report-payment-card" key={method}><span>{method === "CASH" ? "Cash collection" : method === "UPI" ? "UPI collection" : "Card collection"}</span><strong>{formatCurrency(collections[method])}</strong><small>{report?.payments.find((payment) => payment.method === method)?.count ?? 0} payments</small></article>)}</div>
        <h2 className="report-subheading">Table-wise sales</h2>
        {(report?.tableSales.length ?? 0) > 0 ? <div className="report-table-sales">{report?.tableSales.map((sale) => <article key={sale.tableNumber}><span>Table {sale.tableNumber}</span><span>{sale.orders} bills</span><strong>{formatCurrency(sale.amount)}</strong></article>)}</div> : <p className="report-empty">No completed sales for this date.</p>}
      </section>
      <section className="panel report-panel bill-history-panel">
        <div className="panel-heading"><div><div className="panel-kicker">TRANSACTION HISTORY</div><div className="panel-title-row"><h2>Completed bills</h2><span className="total-badge">{todaysBills.length} on selected date</span></div></div></div>
        {todaysBills.length ? <div className="bill-history-list">{todaysBills.map((bill) => <article className="history-bill-row" key={bill.id}><div><strong>{bill.billNumber}</strong><span>Table {bill.table.number} · {bill.payments.map((payment) => payment.method).join(", ")} · {bill.closedAt ? new Date(bill.closedAt).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" }) : ""}</span></div><strong>{formatCurrency(bill.subtotal)}</strong><button className="subtle-button print-receipt-button" onClick={() => void viewReceipt(bill)}>Print / Reprint</button></article>)}</div> : <p className="report-empty">No completed bills recorded for this date.</p>}
      </section>
      <section className="panel report-panel cancelled-history-panel">
        <div className="panel-heading"><div><div className="panel-kicker">AUDIT HISTORY</div><div className="panel-title-row"><h2>Cancelled bills</h2><span className="total-badge">{todaysCancelledBills.length} on selected date</span></div></div></div>
        {todaysCancelledBills.length ? <div className="bill-history-list">{todaysCancelledBills.map((bill) => <article className="history-bill-row cancelled-history-row" key={bill.id}><div><strong>{bill.billNumber}</strong><span>Table {bill.table.number} · Cancelled · {bill.closedAt ? new Date(bill.closedAt).toLocaleTimeString("en-IN", { hour: "2-digit", minute: "2-digit" }) : ""}</span></div><strong>{formatCurrency(bill.subtotal)}</strong></article>)}</div> : <p className="report-empty">No cancelled bills recorded for this date.</p>}
      </section>
      <button className="subtle-button report-print-button" disabled={!report} onClick={() => { setPrintMode("report"); window.setTimeout(() => window.print(), 100); }}>Print report / Save as PDF <ArrowRight size={14} /></button>
      {receipt && settings && <ReceiptPrint receipt={receipt} settings={settings} />}
      {report && settings && <ReportPrint report={report} />}
    </div>
  );
}

function ReportPrint({ report }: { report: DailyReport }) {
  const collections = { CASH: 0, UPI: 0, CARD: 0 };
  for (const payment of report.payments) collections[payment.method] = payment.amount;
  return (
    <article className="report-print-area">
      <header className="receipt-heading"><strong>KOLI WADA DHABA</strong><span>Family Seafood Restaurant</span><span>Daily sales report · {report.businessDate}</span></header>
      <div className="receipt-divider" />
      {(["CASH", "UPI", "CARD"] as const).map((method) => <div className="receipt-meta" key={method}><span>{method} ({report.payments.find((entry) => entry.method === method)?.count ?? 0})</span><strong>{formatCurrency(collections[method])}</strong></div>)}
      <div className="receipt-meta receipt-total"><span>TOTAL COLLECTION</span><strong>{formatCurrency(collections.CASH + collections.UPI + collections.CARD)}</strong></div>
      <div className="receipt-divider" />
      <strong>TABLE-WISE SALES</strong>
      {report.tableSales.map((sale) => <div className="receipt-meta" key={sale.tableNumber}><span>Table {sale.tableNumber} · {sale.orders} bills</span><strong>{formatCurrency(sale.amount)}</strong></div>)}
      <div className="receipt-divider" />
      <strong>COMPLETED BILLS</strong>
      {report.paidBills.map((bill) => <div className="receipt-meta" key={bill.billNumber}><span>{bill.billNumber}</span><strong>{formatCurrency(bill.subtotal)}</strong></div>)}
      <div className="receipt-divider" />
      <strong>CANCELLED BILLS</strong>
      {report.cancelledBills.length ? report.cancelledBills.map((bill) => <div className="receipt-meta" key={bill.billNumber}><span>{bill.billNumber}</span><strong>{formatCurrency(bill.subtotal)}</strong></div>) : <div className="receipt-meta"><span>None</span><span>—</span></div>}
    </article>
  );
}

function ReceiptPrint({ receipt, settings }: { receipt: ReceiptBill; settings: RestaurantSettings }) {
  const payment = receipt.payments[0];
  return (
    <article className={`receipt-print-area receipt-${settings.receiptWidthMm}`} aria-label="Thermal receipt print preview">
      <header className="receipt-heading"><strong>{settings.restaurantName}</strong><span>{settings.subtitle}</span></header>
      <div className="receipt-divider" />
      <div className="receipt-meta"><span>Bill</span><strong>{receipt.billNumber}</strong></div>
      <div className="receipt-meta"><span>Table</span><strong>{receipt.table.number}</strong></div>
      <div className="receipt-meta"><span>Date</span><strong>{receipt.closedAt ? new Date(receipt.closedAt).toLocaleString("en-IN") : "—"}</strong></div>
      <div className="receipt-divider" />
      <div className="receipt-line receipt-columns"><span>ITEM</span><span>QTY</span><span>PRICE</span><span>TOTAL</span></div>
      {receipt.items.map((item, index) => <div className="receipt-line" key={`${item.id}-${index}`}><span className="receipt-item-name">{item.itemName}{item.size ? ` (${item.size})` : ""}</span><span>{item.quantity}</span><span>{formatCurrency(item.unitPrice)}</span><strong>{formatCurrency(item.lineTotal)}</strong></div>)}
      <div className="receipt-divider" />
      <div className="receipt-meta receipt-total"><span>GRAND TOTAL</span><strong>{formatCurrency(receipt.subtotal)}</strong></div>
      <div className="receipt-meta"><span>Payment</span><strong>{payment?.method ?? "—"}</strong></div>
      <footer className="receipt-footer">Thank you. Please visit again.</footer>
    </article>
  );
}

function BillingPage({
  bill,
  categories,
  tables,
  connection,
  token,
  busy,
  error,
  onError,
  onOpenTable,
  onRefreshBill,
  onFinished,
}: {
  bill: CurrentBill | null;
  categories: MenuCategoryData[];
  tables: RestaurantTable[];
  connection: "connecting" | "connected" | "offline";
  token: string;
  busy: boolean;
  error: string;
  onError: (message: string) => void;
  onOpenTable: (number: number, billId?: string) => void;
  onRefreshBill: (billId: string) => Promise<void>;
  onFinished: (message: string) => void;
}) {
  const [search, setSearch] = useState("");
  const [selectedCategory, setSelectedCategory] = useState(categories[0]?.name ?? "");
  const [quantity, setQuantity] = useState("1");
  const [selectedSizes, setSelectedSizes] = useState<Record<string, "FULL" | "HALF">>({});
  const [manualPrices, setManualPrices] = useState<Record<string, string>>({});
  const [otherOpen, setOtherOpen] = useState(false);
  const [otherName, setOtherName] = useState("");
  const [otherPrice, setOtherPrice] = useState("");
  const [otherQuantity, setOtherQuantity] = useState("1");
  const [paymentMethod, setPaymentMethod] = useState<"CASH" | "UPI" | "CARD">("CASH");
  const [paymentOpen, setPaymentOpen] = useState(false);
  const [cashReceived, setCashReceived] = useState("");
  const [upiId, setUpiId] = useState("");
  const [upiPayeeName, setUpiPayeeName] = useState("");
  const [upiConfirmed, setUpiConfirmed] = useState(false);
  const [cardConfirmed, setCardConfirmed] = useState(false);
  const [paymentKey, setPaymentKey] = useState("");
  const [paymentBusy, setPaymentBusy] = useState(false);
  const [actionMessage, setActionMessage] = useState("");

  useEffect(() => {
    if (categories.length > 0 && !categories.some((category) => category.name === selectedCategory)) {
      setSelectedCategory(categories[0].name);
    }
  }, [categories, selectedCategory]);

  useEffect(() => {
    if (bill) setCashReceived(bill.subtotal);
  }, [bill]);

  useEffect(() => {
    if (!paymentOpen) return;
    let active = true;
    void apiRequest<{ upiId: string | null; upiPayeeName: string | null }>("/settings", token)
      .then((settings) => {
        if (active) {
          setUpiId(settings.upiId ?? "");
          setUpiPayeeName(settings.upiPayeeName ?? "");
        }
      })
      .catch((settingsError: unknown) => {
        if (active) {
          console.error("Could not load UPI settings:", settingsError);
          setActionMessage(settingsError instanceof Error ? settingsError.message : "Payment settings unavailable.");
        }
      });
    return () => {
      active = false;
    };
  }, [paymentOpen, token]);

  const selectedMenuCategory = categories.find((category) => category.name === selectedCategory);
  const currentItems = (selectedMenuCategory?.items ?? []).filter(
    (item) => !search.trim() || item.name.toLowerCase().includes(search.trim().toLowerCase()),
  );
  const total = bill?.subtotal ?? "0";
  const filteredCategories = categories.filter((category) =>
    search.trim()
      ? category.name.toLowerCase().includes(search.trim().toLowerCase()) ||
        category.items.some((item) => item.name.toLowerCase().includes(search.trim().toLowerCase()))
      : true,
  );

  async function addItem(item: MenuItemData) {
    if (!bill) {
      onError("Choose a restaurant table before adding items.");
      return;
    }
    const itemQuantity = Number(quantity);
    if (!Number.isSafeInteger(itemQuantity) || itemQuantity < 1 || itemQuantity > 1000) {
      onError("Enter a quantity from 1 to 1000.");
      return;
    }
    const payload: { menuItemId: string; size?: "FULL" | "HALF"; quantity: number; manualPrice?: string } = {
      menuItemId: item.id ?? "",
      quantity: itemQuantity,
    };
    if (item.pricingType === "FULL_HALF") {
      payload.size = selectedSizes[item.id ?? ""] ?? "FULL";
    }
    const isManualPrice =
      item.pricingType === "MANUAL" ||
      (item.pricingType === "FULL_HALF" &&
        ((payload.size === "FULL" && item.fullPrice === null) ||
          (payload.size === "HALF" && item.halfPrice === null)));
    if (isManualPrice) {
      const manualPrice = manualPrices[item.id ?? ""]?.trim();
      if (!manualPrice) {
        onError(`Enter a price for ${item.name}.`);
        return;
      }
      payload.manualPrice = manualPrice;
    }
    try {
      onError("");
      await apiRequest(`/bills/${bill.id}/items`, token, {
        method: "POST",
        body: jsonBody(payload),
      });
      await onRefreshBill(bill.id);
      setActionMessage(`${item.name} added to bill.`);
    } catch (addError) {
      console.error("Could not add menu item to bill:", addError);
      onError(addError instanceof Error ? addError.message : "Could not add this item.");
    }
  }

  async function addOtherItem(event: React.FormEvent<HTMLFormElement>) {
    event.preventDefault();
    if (!bill) return;
    try {
      await apiRequest(`/bills/${bill.id}/items`, token, {
        method: "POST",
        body: jsonBody({
          itemName: otherName,
          manualPrice: otherPrice,
          quantity: Number(otherQuantity),
        }),
      });
      await onRefreshBill(bill.id);
      setOtherName("");
      setOtherPrice("");
      setOtherQuantity("1");
      setOtherOpen(false);
      onError("");
    } catch (addError) {
      console.error("Could not add custom item:", addError);
      onError(addError instanceof Error ? addError.message : "Could not add this custom item.");
    }
  }

  async function changeQuantity(item: BillLine, nextQuantity: number) {
    if (!bill || nextQuantity < 1 || nextQuantity > 1000) return;
    try {
      await apiRequest(`/bills/${bill.id}/items/${item.id}`, token, {
        method: "PATCH",
        body: jsonBody({ quantity: nextQuantity }),
      });
      await onRefreshBill(bill.id);
    } catch (quantityError) {
      console.error("Could not update bill item quantity:", quantityError);
      onError(quantityError instanceof Error ? quantityError.message : "Could not update this quantity.");
    }
  }

  async function removeItem(item: BillLine) {
    if (!bill) return;
    try {
      await apiRequest(`/bills/${bill.id}/items/${item.id}`, token, {
        method: "DELETE",
      });
      await onRefreshBill(bill.id);
    } catch (removeError) {
      console.error("Could not remove bill item:", removeError);
      onError(removeError instanceof Error ? removeError.message : "Could not remove this item.");
    }
  }

  async function confirmPayment() {
    if (!bill) return;
    const key = paymentKey || crypto.randomUUID();
    setPaymentKey(key);
    setPaymentBusy(true);
    try {
      const result = await apiRequest<{ bill: { billNumber: string }; payment: { amount: string } }>(
        `/bills/${bill.id}/payment`,
        token,
        {
          method: "POST",
          body: jsonBody({
            method: paymentMethod,
            idempotencyKey: key,
            ...(paymentMethod === "CASH" ? { cashReceived } : {}),
            ...(paymentMethod === "UPI" ? { upiConfirmed } : {}),
            ...(paymentMethod === "CARD" ? { cardConfirmed } : {}),
          }),
        },
      );
      setPaymentKey("");
      setPaymentOpen(false);
      onFinished(`Payment confirmed: ${result.bill.billNumber} · ${formatCurrency(result.payment.amount)}`);
    } catch (paymentError) {
      console.error("Could not confirm payment:", paymentError);
      onError(paymentError instanceof Error ? paymentError.message : "Payment could not be confirmed.");
    } finally {
      setPaymentBusy(false);
    }
  }

  return (
    <>
      <section className="welcome-row">
        <div>
          <div className="eyebrow"><span className="eyebrow-line" /> POINT OF SALE</div>
          <h1>Restaurant billing<span className="greeting-dot">.</span></h1>
          <p className="welcome-subtitle">One consolidated bill per table. Choose a table to begin.</p>
        </div>
        {bill && <button className="other-item-button" onClick={() => setOtherOpen(true)} disabled={busy}><Plus size={16} /> Other Item</button>}
      </section>
      {error && <div className="app-alert">{error}<button onClick={() => onError("")}>Dismiss</button></div>}
      {actionMessage && <div className="app-alert success-alert">{actionMessage}<button onClick={() => setActionMessage("")}>Dismiss</button></div>}

      {!bill ? (
        <section className="panel tables-page-panel">
          <div className="panel-heading">
            <div><div className="panel-kicker">OPEN AN EXISTING BILL OR START ONE</div><div className="panel-title-row"><h2>Select a table</h2><span className="total-badge">70 tables</span></div></div>
            <div className="table-legend"><span><i className="legend-dot available-dot" />Available</span><span><i className="legend-dot occupied-dot" />Occupied</span></div>
          </div>
          {connection === "connected" && tables.length > 0 ? <div className="table-grid tables-page-grid">
            {tables.map((table) => {
              return (
                <button
                  className={`table-tile ${table.status.toLowerCase()}`}
                  disabled={busy}
                  key={table.number}
                  onClick={() => onOpenTable(table.number, table.currentBill?.id)}
                  aria-label={`Table ${table.number}, ${table.status === "OCCUPIED" ? "occupied" : "available"}`}
                  title={table.status === "OCCUPIED" ? `Table ${table.number} occupied` : `Table ${table.number} available`}
                >
                  <span className="table-number">{String(table.number).padStart(2, "0")}</span><span className="table-order">{table.currentBill ? formatCurrency(table.currentBill.amount) : "Available"}</span>
                </button>
              );
            })}
          </div> : <div className="empty-floor"><div className="empty-illustration"><WifiOff size={21} /></div><strong>Connect the restaurant database to start a bill</strong><span>Tables are loaded from the central database. An offline bill cannot be opened safely.</span></div>}
          <p className="menu-price-note">If a table already has an open bill, the same bill is reopened rather than creating a duplicate.</p>
        </section>
      ) : (
        <div className="billing-layout">
          <section className="panel order-panel">
            <div className="panel-heading">
              <div><div className="panel-kicker">TABLE {bill.table?.number ?? "—"}</div><div className="panel-title-row"><h2>Bill {bill.billNumber}</h2><span className="total-badge">Open</span></div></div>
              <button className="subtle-button" onClick={() => onOpenTable(bill.table?.number ?? 1)} disabled={busy}>Change table</button>
            </div>
            <div className="bill-customer-fields">
              <input id="customer-name" placeholder="Customer name (optional)" maxLength={120} />
              <input id="customer-phone" placeholder="Phone (optional)" maxLength={30} inputMode="tel" />
              <button
                className="subtle-button"
                onClick={async () => {
                  const name = (document.getElementById("customer-name") as HTMLInputElement).value;
                  const phone = (document.getElementById("customer-phone") as HTMLInputElement).value;
                  try {
                    await apiRequest(`/bills/${bill.id}/customer`, token, {
                      method: "PATCH",
                      body: jsonBody({ customerName: name || null, customerPhone: phone || null }),
                    });
                    setActionMessage("Customer details saved.");
                  } catch (customerError) {
                    console.error("Could not save customer details:", customerError);
                    onError(customerError instanceof Error ? customerError.message : "Could not save customer details.");
                  }
                }}
              >
                Save
              </button>
            </div>
            {bill.items.length === 0 ? (
              <div className="empty-floor bill-empty"><div className="empty-illustration"><ShoppingBag size={21} /></div><strong>No items on this bill</strong><span>Select dishes to add them to the table’s bill.</span></div>
            ) : (
              <div className="bill-items-list">
                {bill.items.map((item) => (
                  <article className="bill-line" key={item.id}>
                    <div className="bill-line-name"><strong>{item.itemName}</strong>{item.size && <span>{item.size}</span>}<small>{formatCurrency(item.unitPrice)} each</small></div>
                    <div className="quantity-control"><button aria-label={`Decrease ${item.itemName} quantity`} disabled={busy || item.quantity <= 1} onClick={() => void changeQuantity(item, item.quantity - 1)}>−</button><span>{item.quantity}</span><button aria-label={`Increase ${item.itemName} quantity`} disabled={busy || item.quantity >= 1000} onClick={() => void changeQuantity(item, item.quantity + 1)}>+</button></div>
                    <strong className="bill-line-total">{formatCurrency(item.lineTotal)}</strong>
                    <button className="line-remove" aria-label={`Remove ${item.itemName}`} disabled={busy} onClick={() => void removeItem(item)}><X size={15} /></button>
                  </article>
                ))}
              </div>
            )}
            <div className="bill-summary"><span>Subtotal</span><strong>{formatCurrency(total)}</strong><small>No tax fields are included.</small></div>
            <button className="checkout-button" disabled={busy || bill.items.length === 0} onClick={() => setPaymentOpen(true)}><CreditCard size={17} /> Take payment <span>{formatCurrency(total)}</span></button>
          </section>

          <section className="panel dish-panel">
            <div className="panel-heading"><div><div className="panel-kicker">MENU</div><div className="panel-title-row"><h2>Add items</h2></div></div></div>
            <label className="menu-search billing-search"><Search size={16} /><input value={search} onChange={(event) => { setSearch(event.target.value); if (event.target.value) setSelectedCategory(""); }} placeholder="Search menu..." />{search && <button type="button" onClick={() => { setSearch(""); setSelectedCategory(categories[0]?.name ?? ""); }}>Clear</button>}</label>
            <div className="billing-category-tabs">
              {filteredCategories.map((category) => <button className={`billing-category-tab ${selectedCategory === category.name ? "selected" : ""}`} key={category.name} onClick={() => { setSelectedCategory(category.name); setSearch(""); }}>{category.name}</button>)}
            </div>
            <label className="quantity-input">Default quantity<input type="number" min="1" max="1000" value={quantity} onChange={(event) => setQuantity(event.target.value)} /></label>
            <div className="order-dish-list">
              {(search ? categories.flatMap((category) => category.items.filter((item) => item.name.toLowerCase().includes(search.trim().toLowerCase()))) : currentItems).map((item) => (
                <article className="order-dish" key={item.id ?? item.name}>
                  <div className="order-dish-heading"><strong>{item.name}</strong><span>{item.pricingType === "MANUAL" ? (item.manualPriceNote ?? "Manual price") : item.pricingType === "FULL_HALF" ? `${formatCurrency(item.fullPrice ?? 0)} Full` : formatCurrency(item.fullPrice ?? 0)}</span></div>
                  <div className="order-dish-controls">
                    {item.pricingType === "FULL_HALF" && (
                      <select aria-label={`Size for ${item.name}`} value={selectedSizes[item.id ?? ""] ?? "FULL"} onChange={(event) => setSelectedSizes((sizes) => ({ ...sizes, [item.id ?? ""]: event.target.value as "FULL" | "HALF" }))}>
                        <option value="FULL">Full {item.fullPrice === null ? "(manual price)" : formatCurrency(item.fullPrice)}</option>
                        <option value="HALF">Half {item.halfPrice === null ? "(manual price)" : formatCurrency(item.halfPrice)}</option>
                      </select>
                    )}
                    {(item.pricingType === "MANUAL" || (item.pricingType === "FULL_HALF" && (selectedSizes[item.id ?? ""] ?? "FULL") === "FULL" && item.fullPrice === null) || (item.pricingType === "FULL_HALF" && selectedSizes[item.id ?? ""] === "HALF" && item.halfPrice === null)) && (
                      <input className="manual-price-input" type="number" inputMode="decimal" min="0.01" step="0.01" aria-label={`Manual price for ${item.name}`} placeholder="Enter price" value={manualPrices[item.id ?? ""] ?? ""} onChange={(event) => setManualPrices((prices) => ({ ...prices, [item.id ?? ""]: event.target.value }))} />
                    )}
                    <button className="add-dish-button" disabled={busy || !item.id} onClick={() => void addItem(item)}><Plus size={14} /> Add</button>
                  </div>
                </article>
              ))}
            </div>
            {currentItems.length === 0 && !search && <div className="menu-no-results"><strong>No items in this category.</strong></div>}
          </section>
        </div>
      )}

      {otherOpen && bill && (
        <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget) setOtherOpen(false); }}>
          <section className="dialog-card" role="dialog" aria-modal="true" aria-labelledby="other-heading">
            <div className="panel-heading"><div><div className="panel-kicker">CUSTOM BILL LINE</div><h2 id="other-heading">Add other item</h2></div><button className="icon-button" aria-label="Close dialog" onClick={() => setOtherOpen(false)}><X size={20} /></button></div>
            <p className="dialog-description">Enter the item name and the confirmed price. Nothing will be guessed.</p>
            <form className="dialog-form" onSubmit={(event) => void addOtherItem(event)}>
              <label>Item name<input value={otherName} onChange={(event) => setOtherName(event.target.value)} maxLength={120} required /></label>
              <div className="dialog-fields"><label>Quantity<input type="number" min="1" max="1000" value={otherQuantity} onChange={(event) => setOtherQuantity(event.target.value)} required /></label><label>Price (₹)<input type="number" min="0.01" max="99999999" step="0.01" value={otherPrice} onChange={(event) => setOtherPrice(event.target.value)} required /></label></div>
              <button className="primary-button auth-submit" disabled={busy}>Add custom item</button>
            </form>
          </section>
        </div>
      )}

      {paymentOpen && bill && (
        <div className="modal-backdrop" onMouseDown={(event) => { if (event.target === event.currentTarget && !paymentBusy) setPaymentOpen(false); }}>
          <section className="dialog-card payment-dialog" role="dialog" aria-modal="true" aria-labelledby="payment-heading">
            <div className="panel-heading"><div><div className="panel-kicker">CASHIER CONFIRMED PAYMENT</div><h2 id="payment-heading">Complete this bill</h2></div><button className="icon-button" aria-label="Close payment dialog" onClick={() => !paymentBusy && setPaymentOpen(false)}><X size={20} /></button></div>
            <div className="payment-total"><span>{bill.billNumber} · Table {bill.table?.number}</span><strong>{formatCurrency(total)}</strong></div>
            <div className="payment-methods">
              {(["CASH", "UPI", "CARD"] as const).map((method) => <button className={paymentMethod === method ? "selected" : ""} key={method} onClick={() => { setPaymentMethod(method); setUpiConfirmed(false); setCardConfirmed(false); }}><span>{method === "CASH" ? "Cash" : method === "UPI" ? "UPI" : "Card"}</span><small>{method === "UPI" ? "Manual confirmation" : method === "CARD" ? "Card terminal" : "Cash received"}</small></button>)}
            </div>
            {paymentMethod === "CASH" && <label className="payment-entry">Cash received (₹)<input type="number" min={Number(total)} step="0.01" value={cashReceived} onChange={(event) => setCashReceived(event.target.value)} /></label>}
            {paymentMethod === "UPI" && (
              <div className="upi-payment-details">
                {upiId ? <><div className="upi-qr-card"><QRCodeSVG value={`upi://pay?${new URLSearchParams({ pa: upiId, pn: upiPayeeName || "Koli Wada Dhaba", am: Number(total).toFixed(2), cu: "INR", tn: bill.billNumber }).toString()}`} size={160} level="M" includeMargin /><div className="upi-id-card"><span>Exact amount</span><strong>{formatCurrency(total)}</strong><small>{upiPayeeName || "Koli Wada Dhaba"} · {upiId}</small></div></div><div className="upi-intent-line">Scanning the QR code does not verify payment. Accept UPI only after checking your merchant app.</div><label className="manual-confirm"><input type="checkbox" checked={upiConfirmed} onChange={(event) => setUpiConfirmed(event.target.checked)} /><span>I verified receipt in the merchant's UPI app and received {formatCurrency(total)}.</span></label></> : <div className="app-alert">UPI details are not set. An owner must configure them before requesting a UPI payment.</div>}
              </div>
            )}
            {paymentMethod === "CARD" && <label className="manual-confirm"><input type="checkbox" checked={cardConfirmed} onChange={(event) => setCardConfirmed(event.target.checked)} /><span>I have confirmed payment on the card terminal.</span></label>}
            <button className="checkout-button confirm-payment" disabled={paymentBusy || (paymentMethod === "UPI" && (!upiId || !upiConfirmed)) || (paymentMethod === "CARD" && !cardConfirmed)} onClick={() => void confirmPayment()}>{paymentBusy ? "Confirming..." : `Confirm ${paymentMethod} payment`}<span>{formatCurrency(total)}</span></button>
            <p className="menu-price-note">Payment confirmation is recorded by the cashier. Scanning a QR code or opening an app does not count as successful payment.</p>
          </section>
        </div>
      )}
    </>
  );
}

function TablesPage({
  tables,
  connection,
  availableCount,
  occupiedCount,
  search,
  onSearchChange,
  onSelectTable,
  busy,
}: {
  tables: RestaurantTable[];
  connection: "connecting" | "connected" | "offline";
  availableCount: number;
  occupiedCount: number;
  search: string;
  onSearchChange: (value: string) => void;
  onSelectTable: (number: number, billId?: string) => void;
  busy: boolean;
}) {
  const filteredTables = useMemo(() => {
    const query = search.trim();
    if (!query) return tables;
    return tables.filter((table) => String(table.number).includes(query));
  }, [search, tables]);

  return (
    <>
      <section className="welcome-row">
        <div>
          <div className="eyebrow"><span className="eyebrow-line" /> FLOOR MANAGEMENT</div>
          <h1>Restaurant tables<span className="greeting-dot">.</span></h1>
          <p className="welcome-subtitle">Track table availability across your dining room.</p>
        </div>
      </section>
      <section className="panel tables-page-panel">
        <div className="panel-heading">
          <div><div className="panel-kicker">TABLE STATUS</div><div className="panel-title-row"><h2>Table overview</h2><span className="total-badge">{connection === "connected" ? `${tables.length} tables` : "70 tables"}</span></div></div>
          <div className="table-legend"><span><i className="legend-dot available-dot" />Available</span><span><i className="legend-dot occupied-dot" />Occupied</span></div>
        </div>
        <label className="search-field tables-search"><Search size={16} /><input value={search} onChange={(event) => onSearchChange(event.target.value)} placeholder="Find a table..." /></label>
        {connection === "connected" && tables.length > 0 ? (
          filteredTables.length > 0 ? (
            <div className="table-grid tables-page-grid">
              {filteredTables.map((table) => (
                <button
                  className={`table-tile ${table.status.toLowerCase()}`}
                  disabled={busy}
                  onClick={() => onSelectTable(table.number, table.currentBill?.id)}
                  key={table.number}
                  aria-label={`Table ${table.number}, ${table.status === "OCCUPIED" ? "occupied" : "available"}${table.currentBill ? `, bill ${formatCurrency(table.currentBill.amount)}` : ""}`}
                  title={table.currentBill ? `${table.currentBill.billNumber} · ${formatCurrency(table.currentBill.amount)}` : `Table ${table.number} · Available`}
                >
                  <span className="table-number">{String(table.number).padStart(2, "0")}</span>
                  {table.currentBill ? <span className="table-order">{formatCurrency(Number(table.currentBill.amount))}</span> : <span className="table-order">Available</span>}
                </button>
              ))}
            </div>
          ) : <div className="search-empty">No tables match “{search}”.</div>
        ) : (
          <div className="empty-floor">
            <div className="empty-illustration"><Utensils size={23} /></div>
            <strong>Table status is not connected yet</strong>
            <span>Connect and seed the PostgreSQL database to load the 70 live restaurant tables.</span>
            <span>{connection === "connected" ? "Run npm run db:seed from the project folder." : "Check the API and database connection."}</span>
          </div>
        )}
        {connection === "connected" && <div className="table-panel-footer"><span><i className="legend-dot available-dot" />{availableCount} available</span><span><i className="legend-dot occupied-dot" />{occupiedCount} occupied</span><span className="refresh-note"><Clock3 size={13} />Updates every 15 seconds</span></div>}
      </section>
    </>
  );
}

function MetricCard({
  icon,
  iconClass,
  label,
  value,
  meta,
  trend,
}: {
  icon: React.ReactNode;
  iconClass: string;
  label: string;
  value: string;
  meta: string;
  trend: React.ReactNode;
}) {
  return (
    <article className="metric-card">
      <div className="metric-top">
        <span className={`metric-icon ${iconClass}`}>{icon}</span>
        <span className="metric-more"><MoreHorizontal size={18} /></span>
      </div>
      <div className="metric-label">{label}</div>
      <div className="metric-value">{value}</div>
      <div className="metric-bottom"><span className="metric-meta">{meta}</span><span>{trend}</span></div>
    </article>
  );
}

export default App;
