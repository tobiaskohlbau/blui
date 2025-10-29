import type { PageLoad } from './$types';

export const load: PageLoad = async ({ params, fetch }) => {
	const status = await fetch(`/api/printer/status`).then((r) => r.json());
	const image = await fetch(`/api/webcam.jpg`)
		.then((r) => r.blob())
		.then(
			(blob) =>
				new Promise((callback) => {
					let reader = new FileReader();
					reader.onload = function () {
						callback(this.result);
					};
					reader.readAsDataURL(blob);
				})
		);

	return {
		...status,
		image: image
	};
};
