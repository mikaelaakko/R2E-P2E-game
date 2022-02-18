from brownie import THRONE, GameOfRisk, Seed, accounts
from scripts.helper_functions import get_account


def deploy():
    account = get_account()

    throne_con = Seed.deploy(
        {"from": account},
        publish_source=True,
    )


def add_seed():
    account = get_account()

    seed_con = Seed[-1]
    game_con = GameOfRisk[-1]

    add_tx = game_con.setRandomSource(seed_con, {"from": account})
    add_tx.wait(1)


def main():
    deploy()
    add_seed()
