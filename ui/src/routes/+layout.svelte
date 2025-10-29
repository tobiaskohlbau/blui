<script lang="ts">
	import favicon from '$lib/assets/favicon.svg';

	let { children } = $props();
</script>

<svelte:head>
	<link rel="icon" href={favicon} />
</svelte:head>

<div class="app">
	<aside class="sidebar">
		<div class="brand">
			<div class="logo">blUI</div>
			<div>
				<h1>blUI</h1>
				<div class="small">Cloudless by Design</div>
			</div>
		</div>

		<nav class="nav">
			<a href="/" class="active">Dashboard</a>
		</nav>
	</aside>

	<main class="main">
		{@render children?.()}
	</main>
</div>

<style>
	:global {
		:root {
			--bg: #0f1724;
			--card: #0b1220;
			--muted: #98a0b3;
			--accent: #6ee7b7;
			--accent-2: #60a5fa;
			--glass: rgba(255, 255, 255, 0.04);
			--radius: 14px;
			--shadow: 0 6px 18px rgba(2, 6, 23, 0.6);
			font-family:
				Inter,
				ui-sans-serif,
				system-ui,
				-apple-system,
				'Segoe UI',
				Roboto,
				'Helvetica Neue',
				Arial;
		}

		* {
			box-sizing: border-box;
		}

		html,
		body {
			height: 100%;
			margin: 0;
			background: linear-gradient(180deg, var(--bg) 0%, #08101a 100%);
			color: #e6eef8;
		}

		a {
			color: var(--accent-2);
			text-decoration: none;
		}

		.app {
			display: grid;
			grid-template-columns: 260px 1fr;
			gap: 20px;
			min-height: 100vh;
			padding: 28px;
		}

		.sidebar {
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.02), rgba(255, 255, 255, 0.015));
			padding: 18px;
			border-radius: 16px;
			box-shadow: var(--shadow);
		}

		.brand {
			display: flex;
			align-items: center;
			gap: 12px;
			margin-bottom: 10px;

			h1 {
				font-size: 16px;
				margin: 0;
			}
		}

		.logo {
			width: 44px;
			height: 44px;
			border-radius: 10px;
			background: linear-gradient(135deg, var(--accent), var(--accent-2));
			display: flex;
			align-items: center;
			justify-content: center;
			font-weight: 700;
		}

		.nav {
			margin-top: 12px;
			a {
				display: flex;
				align-items: center;
				padding: 10px;
				border-radius: 10px;
				color: var(--muted);
				gap: 10px;
				margin-bottom: 6px;

				&.active,
				&:hover {
					background: var(--glass);
					color: var(--accent-2);
				}
			}
		}

		.main {
			padding: 18px;
			border-radius: 16px;
			background: linear-gradient(180deg, rgba(255, 255, 255, 0.01), rgba(255, 255, 255, 0.005));
			box-shadow: var(--shadow);
		}
	}
</style>
