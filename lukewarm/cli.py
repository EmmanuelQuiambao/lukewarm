import click

from lukewarm import __version__


@click.group()
@click.version_option(__version__)
def main():
    """Lukewarm — declarative SQL models over Apache Iceberg."""
    pass


@main.command()
def run():
    """Trigger a materialization run for all models."""
    raise NotImplementedError("Coming soon")


@main.command()
def status():
    """Show the materialization status of all models."""
    raise NotImplementedError("Coming soon")
